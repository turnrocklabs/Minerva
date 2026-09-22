#!/usr/bin/env python3
"""Build Minerva's native test inputs from a commit, isolated and cached.

    build.py ensure --rev REV [--component NAME ...] [--manifest OUT.json]
    build.py keys   --rev REV            # cache keys only; builds nothing

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
A failed build leaves its log under <cache>/builds/_failed/ and exits 1.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
IMAGE_DIR = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("MINERVA_CT_CACHE",
                            Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
                            / "minerva-container-tests"))
LABEL = "minerva-container-build"

# component -> how to build it. inputs: repo paths whose content at REV the
# output depends on. submodules: checked out before the command runs.
# outputs: files or directories copied out, at the path the tests expect.
RECIPES = {
    "terminal": {
        "inputs": ["src/gdextension/terminal", "src/SConstruct", "src/godot-cpp",
                   "vendor/ghostty", "scripts/build-extensions.sh"],
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


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def ensure_image() -> tuple[str, str]:
    """Build (once) and return the builder image tag and id."""
    digest = hashlib.sha256((IMAGE_DIR / "Dockerfile").read_bytes()).hexdigest()[:12]
    tag = f"minerva-container-build:{digest}"
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


def build(name: str, recipe: dict, sha: str, key: str, ids: dict, image: tuple[str, str],
          dest: Path) -> None:
    tag, image_id = image
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    work = CACHE / "builds" / "_tmp" / f"{name}-{key}-{os.getpid()}"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    downloads = CACHE / "downloads"
    for sub in ("cargo", "zig", "cef-home"):
        (downloads / sub).mkdir(parents=True, exist_ok=True)
    git_dir = Path(git("rev-parse", "--absolute-git-dir"))
    started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    cmd = ["docker", "run", "--rm", "--init", "--name", f"minerva-cb-{name}-{key[:12]}",
           "--label", f"{LABEL}={name}", "--cap-drop", "ALL",
           "--security-opt", "no-new-privileges", "--user", f"{os.getuid()}:{os.getgid()}",
           "--cpus", os.environ.get("MINERVA_CB_CPUS", "12"),
           "--memory", os.environ.get("MINERVA_CB_MEMORY", "24g"),
           "--memory-swap", os.environ.get("MINERVA_CB_MEMORY", "24g"), "--pids-limit", "8192",
           "-v", f"{git_dir}:/hostgit:ro", "-v", f"{work}:/out",
           "-v", f"{downloads / 'cargo'}:/cache/cargo", "-v", f"{downloads / 'zig'}:/cache/zig",
           # build-godot-cef.sh exports the CEF bundle under $HOME/.local/share/cef.
           "-v", f"{downloads / 'cef-home'}:/home/builder/.local/share/cef",
           "-e", "CARGO_HOME=/cache/cargo", "-e", "ZIG_GLOBAL_CACHE_DIR=/cache/zig",
           "-e", f"REV={sha}", "-e", f"SUBMODULES={' '.join(recipe['submodules'])}",
           "-e", f"COMMAND={recipe['command']}", "-e", f"OUTPUTS={' '.join(recipe['outputs'])}",
           tag, "bash", "-c", IN_CONTAINER]
    print(f"[{name}] building {key} at {sha[:12]}: {recipe['command']}", file=sys.stderr)
    with open(work / "build.log", "w") as log:
        rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        failed = CACHE / "builds" / "_failed" / f"{name}-{key}-{stamp}"
        failed.parent.mkdir(parents=True, exist_ok=True)
        work.rename(failed)
        raise SystemExit(f"[{name}] build failed (exit {rc}); log: {failed / 'build.log'}")

    provenance = {
        "component": name, "key": key, "revision": sha, "inputs": ids,
        "submodules": {sm: ids[sm] for sm in recipe["submodules"]},
        "command": recipe["command"], "outputs": recipe["outputs"],
        "builder_image": {"tag": tag, "id": image_id},
        "toolchain": (work / "toolchain.txt").read_text().splitlines(),
        "started_utc": started,
        "finished_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "files": hash_outputs(work / "files"),
    }
    (work / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    subprocess.run(["chmod", "-R", "a-w", str(work)], check=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.rename(work, dest)  # dest is absent: the caller holds the key's lock


def plan(sha: str, names: list[str], image_id: str) -> dict:
    return {name: (ids := input_ids(sha, RECIPES[name]),
                   cache_key(name, RECIPES[name], ids, image_id)) for name in names}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["ensure", "keys"])
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--component", action="append", choices=sorted(RECIPES))
    parser.add_argument("--manifest", type=Path, help="write the ensure result as JSON here")
    args = parser.parse_args()

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
        dest = CACHE / "builds" / name / key
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest.parent / f"{key}.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)  # a concurrent job building the same key waits
            hit = dest.exists()
            if hit:
                print(f"[{name}] cache hit {key}", file=sys.stderr)
            else:
                build(name, RECIPES[name], sha, key, ids, image, dest)
        os.utime(dest)  # marks it in use for container-test.sh prune
        manifest["components"][name] = {"key": key, "cache_hit": hit, "dir": str(dest),
                                        "outputs": RECIPES[name]["outputs"]}
    if args.manifest:
        args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
