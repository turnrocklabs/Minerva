#!/usr/bin/env python3
"""Build Minerva's native test inputs from a commit, isolated and cached.

    build.py ensure --rev REV [--component NAME ...] [--manifest OUT.json]
    build.py keys   --rev REV            # cache keys only; builds nothing
    build.py mount-rows --manifest M --provenance-dir D
                                         # "<src>\t<target>" mount rows for M's
                                         # outputs, after re-verifying every entry

Each component in RECIPES is built by the repo's own entry point, inside a
container of the pinned builder image (Dockerfile here), from a fresh clone of
REV taken from this repo's read-only object store. Only the submodules a
recipe declares are checked out, at the commit REV records, so dirty host
working trees never reach a build.

A build is cached under <cache>/builds/<component>/<key>, read-only. The key
hashes the recipe, the builder image id and the git object id at REV of every
declared input path (a tree, blob or submodule commit), so a commit that
touches none of a component's inputs reuses its build and one that touches any
input rebuilds just that component. provenance.json beside the outputs records
the inputs, toolchain versions, command and the sha256 of every output file.

Builds run with network access for their pinned fetches (crates via
Cargo.lock, zig deps by hash, the jsoncons tarball by sha256, the CEF bundle,
the sqlite/ffmpeg release archives); tests that consume the outputs do not.
A build's only writable host mount is its own fresh work directory; download
caches stay inside the builder container.
No deletes or replacements: each build works in a fresh uniquely named
directory beside its destination and publishes with publish.py's no-clobber
rename (renameat2 RENAME_NOREPLACE, no fallback). A failed build is renamed,
also no-clobber, to <component>/.failed-<key>-* with its log. An existing entry
is used only when its provenance names its key and every declared output is
present with its recorded type and the recorded tree digest (never read
through a symlink); otherwise the run fails and nothing is touched — not even
an entry's mtime. Reclaiming disk is a separate, reviewed step (not
implemented).
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
IMAGE_DIR = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ beside the tooling
sys.path.insert(0, str(IMAGE_DIR))
import stat  # noqa: E402
from publish import (PublishError, entry_type, publish_tree, rename_noreplace,  # noqa: E402
                     tree_digest, tree_problem)
LABEL = "minerva-container-build"

# component -> how to build it. inputs: repo paths whose content at REV the
# output depends on. submodules: checked out before the command runs.
# outputs: files or directories copied out, at the path the tests expect.
RECIPES = {
    "terminal": {
        "inputs": ["src/gdextension/terminal", "src/SConstruct", "src/godot-cpp",
                   "vendor/ghostty", "scripts/build-extensions.sh", "scripts/zig-prefetch.py"],
        "submodules": ["src/godot-cpp", "vendor/ghostty"],
        "command": "scripts/build-extensions.sh linux --terminal-only",
        "outputs": ["src/bin/libterminal.linux.template_debug.x86_64.so",
                    "src/bin/libminerva-vt.so"],
    },
    "json-schema-helper": {
        "inputs": ["src/native/json_schema_helper", "scripts/build-json-schema-helper.py",
                   "scripts/build-mcp-schema-helper.sh"],
        "submodules": [],
        "command": "scripts/build-mcp-schema-helper.sh linux-x86_64",
        "outputs": ["src/bin/minerva-json-schema-helper"],
    },
    "agent-relay": {
        "inputs": ["src/plugins/agent-relay", "scripts/build-extensions.sh"],
        "submodules": [],
        "command": "scripts/build-extensions.sh linux --agent-relay-only",
        "outputs": ["src/plugins/agent-relay/runtime-build/stage/linux-x86_64"],
    },
    "godot-cef": {
        "inputs": ["vendor/godot_cef", "patches/godot_cef", "scripts/build-godot-cef.sh"],
        "submodules": ["vendor/godot_cef"],
        "command": "scripts/build-godot-cef.sh linux",
        "outputs": ["src/addons/godot_cef/bin/x86_64-unknown-linux-gnu"],
    },
    "addons": {
        "inputs": ["scripts/build-extensions.sh"],
        "submodules": [],
        "command": "scripts/build-extensions.sh linux --addons-only",
        "outputs": ["src/addons/godot-sqlite/bin", "src/addons/ffmpeg/linux64"],
    },
}

# Runs inside the builder container as the host uid. /hostgit is this repo's
# .git, read-only; `clone --shared` borrows its objects without writing there.
IN_CONTAINER = r"""
set -euo pipefail
git config --global protocol.file.allow always
git config --global advice.detachedHead false
git clone -q --shared --no-checkout /hostgit /work/src
cd /work/src
git checkout -q --detach "$REV"
for sm in $SUBMODULES; do
    git config "submodule.$sm.url" "/hostgit/modules/$sm"
    git submodule update --init "$sm"
done
echo "== source: $(git rev-parse HEAD)"
git submodule status $SUBMODULES || true
echo "== command: $COMMAND"
bash -c "$COMMAND"
mkdir -p /out/files
for path in $OUTPUTS; do
    [ -e "$path" ] || { echo "declared output missing: $path" >&2; exit 3; }
    mkdir -p "/out/files/$(dirname "$path")"
    cp -a "$path" "/out/files/$path"
done
{
    echo "zig $(zig version)"
    rustc --version
    rustc +nightly-2026-06-21 --version
    scons --version | grep -m1 -i 'engine' || true
    c++ --version | head -1
    cmake --version | head -1
} > /out/toolchain.txt 2>&1
"""


def cache_root() -> Path:
    """The cache root, validated once; the same rules as container-test.sh.

    MINERVA_CT_CACHE, when set, must be a non-empty absolute path. The root
    may not be a symlink (tested after dropping trailing slashes, which Path
    does), /, $HOME or above it, or this repo or above it. This assumes nothing
    else mutates the cache concurrently; a symlinked ancestor is not refused.
    """
    override = os.environ.get("MINERVA_CT_CACHE")
    if override is not None and not os.path.isabs(override):
        raise SystemExit(f"MINERVA_CT_CACHE must be an absolute path, got {override!r}")
    xdg = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    lexical = Path(override if override is not None else os.path.join(xdg, "minerva-container-tests"))
    if lexical.is_symlink():
        raise SystemExit(f"refusing cache root {lexical}: it is a symlink")
    root = Path(os.path.realpath(lexical))
    home = Path(os.path.realpath(Path.home()))
    if root == Path("/") or root == home or root in home.parents or root == REPO or root in REPO.parents:
        raise SystemExit(f"refusing cache root {root}: too broad")
    return root


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def builder_tag() -> str:
    """The builder image tag: a content hash of its Dockerfile, so it needs no docker."""
    digest = hashlib.sha256((IMAGE_DIR / "Dockerfile").read_bytes()).hexdigest()[:12]
    return f"minerva-container-build:{digest}"


def ensure_image() -> tuple[str, str]:
    """Build (once) and return the builder image tag and id."""
    tag = builder_tag()
    probe = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", tag],
                           capture_output=True, text=True)
    if probe.returncode != 0:
        print(f"building builder image {tag}", file=sys.stderr)
        subprocess.run(["docker", "build", "-q", "-t", tag, "-f", str(IMAGE_DIR / "Dockerfile"),
                        str(IMAGE_DIR)], check=True, stdout=subprocess.DEVNULL)
        probe = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", tag],
                               capture_output=True, text=True, check=True)
    return tag, probe.stdout.strip()


def input_ids(sha: str, recipe: dict) -> dict:
    """Git object id of each declared input at the commit; missing is an error."""
    ids = {}
    for path in recipe["inputs"]:
        try:
            ids[path] = git("rev-parse", "--verify", f"{sha}:{path}")
        except subprocess.CalledProcessError:
            raise SystemExit(f"recipe input {path} does not exist at {sha}")
    return ids


def cache_key(name: str, recipe: dict, ids: dict, image_id: str) -> str:
    material = json.dumps({"component": name, "recipe": recipe, "inputs": ids,
                           "builder_image": image_id}, sort_keys=True)
    return hashlib.sha256(material.encode()).hexdigest()[:32]


def hash_outputs(root: Path) -> dict:
    hashes = {}
    for f in sorted(p for p in root.rglob("*") if p.is_file() or p.is_symlink()):
        rel = str(f.relative_to(root))
        hashes[rel] = ("symlink:" + os.readlink(f)) if f.is_symlink() else \
            hashlib.sha256(f.read_bytes()).hexdigest()
    return hashes


def build(cache: Path, name: str, recipe: dict, sha: str, key: str, ids: dict,
          image: tuple[str, str], dest: Path) -> None:
    tag, image_id = image
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    # Unique and beside dest, so publishing is a same-directory rename.
    work = Path(tempfile.mkdtemp(prefix=f".tmp-{key}-", dir=dest.parent))
    git_dir = Path(git("rev-parse", "--absolute-git-dir"))
    started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    cmd = ["docker", "run", "--rm", "--init", "--name", f"minerva-cb-{name}-{key[:12]}",
           "--label", f"{LABEL}={name}", "--cap-drop", "ALL",
           "--security-opt", "no-new-privileges", "--user", f"{os.getuid()}:{os.getgid()}",
           "--cpus", os.environ.get("MINERVA_CB_CPUS", "12"),
           "--memory", os.environ.get("MINERVA_CB_MEMORY", "24g"),
           "--memory-swap", os.environ.get("MINERVA_CB_MEMORY", "24g"), "--pids-limit", "8192",
           # The only writable host mount is this build's own fresh work dir.
           # Download caches (cargo, zig, the CEF bundle) stay in the container:
           # the build scripts clean and --force them, which must never reach
           # the host. A rebuild re-downloads; builds are cached per key.
           "-v", f"{git_dir}:/hostgit:ro", "-v", f"{work}:/out",
           "-e", f"REV={sha}", "-e", f"SUBMODULES={' '.join(recipe['submodules'])}",
           "-e", f"COMMAND={recipe['command']}", "-e", f"OUTPUTS={' '.join(recipe['outputs'])}",
           tag, "bash", "-c", IN_CONTAINER]
    print(f"[{name}] building {key} at {sha[:12]}: {recipe['command']}", file=sys.stderr)
    with open(work / "build.log", "w") as log:
        rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        raise SystemExit(f"[{name}] build failed (exit {rc}); log: {keep_failed(work, key, stamp)}/build.log")
    try:
        publish(name, recipe, sha, key, ids, image, started, work, dest)
    except BaseException:
        print(f"[{name}] publish failed; kept {keep_failed(work, key, stamp)}", file=sys.stderr)
        raise


def keep_failed(work: Path, key: str, stamp: str) -> Path:
    """Rename a failed build's work dir (log included) to .failed-<key>-<stamp>-*
    in the same directory, never replacing anything. Returns where it now is
    (work itself if the rename was refused)."""
    failed = work.with_name(f".failed-{key}-{stamp}-{work.name.rsplit('-', 1)[-1]}")
    try:
        return failed if rename_noreplace(str(work), str(failed)) == "published" else work
    except PublishError:
        return work


def publish(name: str, recipe: dict, sha: str, key: str, ids: dict, image: tuple[str, str],
            started: str, work: Path, dest: Path) -> None:
    """Write provenance.json and move the finished build to dest, read-only."""
    tag, image_id = image
    files = str(work / "files")
    problem = tree_problem(files)
    if problem:
        raise PublishError(f"build output breaks the symlink policy: {problem}")
    output_types = {out: entry_type(files, out) for out in recipe["outputs"]}
    bad = {out: kind for out, kind in output_types.items() if kind not in ("file", "dir")}
    if bad:
        raise PublishError(f"declared outputs are not plain files or directories: {bad}")
    provenance = {
        "component": name, "key": key, "revision": sha, "inputs": ids,
        "submodules": {sm: ids[sm] for sm in recipe["submodules"]},
        "command": recipe["command"], "outputs": recipe["outputs"],
        "builder_image": {"tag": tag, "id": image_id},
        "toolchain": (work / "toolchain.txt").read_text().splitlines(),
        "started_utc": started,
        "finished_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "files": hash_outputs(work / "files"),
        "files_digest": tree_digest(files),
        "output_types": output_types,
    }
    (work / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    # Read-only, then a no-clobber same-directory rename: dest is absent or
    # complete. The caller holds the key's lock, so "exists" means a writer
    # that ignored it; that entry is accepted only if it verifies.
    if publish_tree(str(work), str(dest)) == "exists":
        if not verify_entry(dest, key, recipe):
            raise PublishError(f"{dest} appeared during the build and does not verify; "
                               f"left it and kept this build at {work}")
        print(f"[{name}] {dest} was published concurrently and verifies; kept {work}", file=sys.stderr)


def verify_entry(dest: Path, key: str, recipe: dict) -> bool:
    """A published entry is usable when dest and dest/files are real
    directories, dest/provenance.json is a regular file naming this key, every
    declared output has its recorded type (reached without passing through a
    symlink), the symlink policy holds, and files/ matches the recorded tree
    digest. Anything odd — including I/O errors — is simply "not usable"."""
    try:
        if not stat.S_ISDIR(os.lstat(dest).st_mode):
            return False
        prov_path = dest / "provenance.json"
        if not stat.S_ISREG(os.lstat(prov_path).st_mode):
            return False
        prov = json.loads(prov_path.read_text())
        files = str(dest / "files")
        if not stat.S_ISDIR(os.lstat(files).st_mode):
            return False
        if not isinstance(prov, dict) or prov.get("key") != key:
            return False
        types = prov.get("output_types")
        if not isinstance(types, dict):
            return False
        for out in recipe["outputs"]:  # recorded and actual: the same plain type
            if types.get(out) not in ("file", "dir") or entry_type(files, out) != types[out]:
                return False
        return tree_problem(files) == "" and prov.get("files_digest") == tree_digest(files)
    except (OSError, ValueError):
        return False


def mount_rows(manifest_path: Path, provenance_dir: Path) -> int:
    """Print one "<source>\t<target>" row per declared output of an `ensure`
    manifest, copying each entry's provenance.json into provenance_dir. Every
    entry is re-verified and every copy made BEFORE any row is printed, so a
    failure yields exit 3 and no rows — never a partial mount list. Copies are
    exclusive-create: an existing file there is an error, not overwritten."""
    try:
        manifest = json.loads(manifest_path.read_text())
        rows, entries = [], []
        for name, comp in manifest["components"].items():
            recipe = RECIPES.get(name)
            entry = Path(comp["dir"])
            if recipe is None or comp.get("outputs") != recipe["outputs"]:
                raise ValueError(f"{name}: not a known component or outputs differ from its recipe")
            if not verify_entry(entry, comp["key"], recipe):
                raise ValueError(f"{name}: entry {entry} does not verify")
            entries.append((name, entry))
            rows += [f"{entry / 'files' / out}\t{out}" for out in recipe["outputs"]]
        if not rows:
            raise ValueError("manifest lists no outputs")
        for name, entry in entries:
            with open(entry / "provenance.json", "rb") as src, open(provenance_dir / f"{name}.json", "xb") as dst:
                dst.write(src.read())
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        print(f"mount-rows refused: {e}", file=sys.stderr)
        return 3
    print("\n".join(rows))
    return 0


def plan(sha: str, names: list[str], image_id: str) -> dict:
    return {name: (ids := input_ids(sha, RECIPES[name]),
                   cache_key(name, RECIPES[name], ids, image_id)) for name in names}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["ensure", "keys", "mount-rows"])
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--component", action="append", choices=sorted(RECIPES))
    parser.add_argument("--manifest", type=Path,
                        help="ensure: write the result as JSON here; mount-rows: read it")
    parser.add_argument("--provenance-dir", type=Path, help="mount-rows: copy provenance here")
    args = parser.parse_args()
    if args.action == "mount-rows":  # no git, no docker: reads a finished manifest
        if not args.manifest or not args.provenance_dir:
            parser.error("mount-rows needs --manifest and --provenance-dir")
        return mount_rows(args.manifest, args.provenance_dir)

    cache = cache_root()
    sha = git("rev-parse", "--verify", f"{args.rev}^{{commit}}")
    names = args.component or list(RECIPES)
    image = ensure_image()
    keys = plan(sha, names, image[1])
    if args.action == "keys":
        for name, (ids, key) in keys.items():
            print(f"{name:<20} {key}  " + " ".join(f"{p}={i[:10]}" for p, i in ids.items()))
        return 0

    manifest = {"revision": sha, "builder_image": {"tag": image[0], "id": image[1]}, "components": {}}
    for name, (ids, key) in keys.items():
        dest = cache / "builds" / name / key
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest.parent / f"{key}.lock", "a") as lock:  # "a": never truncates
            fcntl.flock(lock, fcntl.LOCK_EX)  # a concurrent job building the same key waits
            hit = os.path.lexists(dest)
            if hit and not verify_entry(dest, key, RECIPES[name]):
                raise SystemExit(f"[{name}] cache entry {dest} is incomplete or foreign; "
                                 "not using or deleting it — move it aside by hand after review")
            if hit:
                print(f"[{name}] cache hit {key}", file=sys.stderr)
            else:
                build(cache, name, RECIPES[name], sha, key, ids, image, dest)
        manifest["components"][name] = {"key": key, "cache_hit": hit, "dir": str(dest),
                                        "outputs": RECIPES[name]["outputs"]}
    if args.manifest:
        args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
