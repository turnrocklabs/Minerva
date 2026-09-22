#!/usr/bin/env python3
"""Stage Minerva's native binaries into this working clone, for dev tests in an
agent container (scripts/dev-test.sh runs it first).

    dev-natives.py [--component NAME ...]

Every component in build.py's RECIPES ends in one of three states:
  up to date  the component's stamp (<git dir>/minerva-dev-natives/<name>.json)
              records the current input fingerprint, and every output still
              has the type and digest the stamp recorded (a cached entry is
              re-verified too): nothing to do.
  cached      the inputs are unedited and the launcher's read-only manifest
              ($MINERVA_NATIVES_MANIFEST) names the builder image and build
              cache; the entry for the key recomputed here verifies, so each
              output becomes a symlink into that read-only cache.
  local       otherwise (edited inputs, or no entry for the key): the recipe's
              own command builds in this clone with the image's toolchains,
              which are the builder image's.
The input fingerprint covers the component, its recipe, the builder image,
the inputs' object ids at HEAD and every uncommitted change under them,
recursing into initialized submodules. The old stamp is removed before any
output is touched, and a new one is written only after every output exists,
so a failed build never leaves a stamp vouching for old binaries.
Refused loudly, never worked around: a cache entry that exists but does not
verify, an image built from a different builder Dockerfile than this clone's,
an output path holding tracked or unignored files, and a failed local build.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build  # noqa: E402
from publish import entry_type, tree_digest  # noqa: E402

REPO = build.REPO


class Refused(Exception):
    pass


def git(where: Path, *args: str, check: bool = True) -> bytes:
    done = subprocess.run(["git", "-C", str(where), *args], check=check, capture_output=True)
    return done.stdout


def stamps_dir() -> Path:
    return Path(git(REPO, "rev-parse", "--absolute-git-dir").decode().strip()) / "minerva-dev-natives"


def trusted_manifest() -> dict | None:
    """The launcher's {"builder_image": {"tag", "id"}, "cache": root or null},
    or None outside an agent container (then everything builds locally)."""
    path = os.environ.get("MINERVA_NATIVES_MANIFEST")
    if not path or not os.path.exists(path):
        return None
    manifest = json.loads(Path(path).read_text())
    if manifest["builder_image"]["tag"] != build.builder_tag():
        raise Refused(f"this image was built on {manifest['builder_image']['tag']}, but this clone's "
                      f"builder Dockerfile is {build.builder_tag()}: rebuild the agent image "
                      "(agent.py build) so toolchains and cache keys match")
    return manifest


def worktree_state(where: Path, paths: list[str]) -> tuple[bytes, bool]:
    """Every uncommitted change under paths in the repo at where: status, diff,
    untracked bytes, and the same for each initialized submodule, recursively.
    Returns (the bytes to hash, whether anything is edited or untracked)."""
    status = git(where, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *paths)
    state = status + git(where, "diff", "HEAD", "--binary", "--", *paths)
    for entry in status.split(b"\0"):
        if entry.startswith(b"?? "):  # untracked files have no diff: hash their bytes
            state += (where / entry[3:].decode()).read_bytes()
    for line in git(where, "ls-files", "-s", "-z", "--", *paths).split(b"\0"):
        if line.startswith(b"160000 "):  # a gitlink: the submodule's own work tree
            sub = where / line.split(b"\t", 1)[1].decode()
            if (sub / ".git").exists():
                inner, _ = worktree_state(sub, ["."])
                state += str(sub).encode() + git(sub, "rev-parse", "HEAD") + inner
    return state, bool(status)


def fingerprint(name: str, recipe: dict, ids: dict, builder: dict) -> tuple[str, bool]:
    """(hash of everything a build of this component depends on, whether any input is edited)."""
    state, edited = worktree_state(REPO, recipe["inputs"])
    material = json.dumps({"component": name, "recipe": recipe, "inputs": ids, "builder_image": builder},
                          sort_keys=True).encode()
    return hashlib.sha256(material + b"\0" + state).hexdigest(), edited


def output_state(out: str) -> dict:
    """An output's type and content digest (a symlink's digest covers its target text)."""
    kind = entry_type(str(REPO), out)
    staged = kind in ("file", "dir", "symlink")
    return {"type": kind, "digest": tree_digest(str(REPO / out)) if staged else None}


def still_valid(name: str, recipe: dict, stamp: dict, manifest: dict | None) -> bool:
    if any(output_state(out) != stamp.get("outputs", {}).get(out) for out in recipe["outputs"]):
        return False
    if stamp.get("source") != "cache":
        return True
    if not manifest or not manifest.get("cache"):
        return False
    entry = Path(manifest["cache"]) / "builds" / name / stamp["key"]
    return build.verify_entry(entry, stamp["key"], recipe)


def check_replaceable(out: str) -> None:
    """An output may be replaced only if nothing at or under it is tracked, it
    is not reached through a symlinked parent, and every file under it is one
    git ignores. A symlink (a previous cache staging) is always replaceable:
    unlinking it destroys nothing."""
    kind = entry_type(str(REPO), out)
    if kind == "blocked":
        raise Refused(f"{out}: a parent is a symlink or not a directory")
    if git(REPO, "ls-files", "-z", "--", out):
        raise Refused(f"{out} holds tracked files; refusing to replace it")
    if kind in ("file", "dir") and git(REPO, "ls-files", "-z", "--others", "--exclude-standard", "--", out):
        raise Refused(f"{out} holds files git does not ignore; refusing to replace it")


def remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def stage(name: str, manifest: dict | None) -> str:
    recipe = build.RECIPES[name]
    builder = manifest["builder_image"] if manifest else {"tag": build.builder_tag(), "id": None}
    head = git(REPO, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    ids = build.input_ids(head, recipe)
    current, edited = fingerprint(name, recipe, ids, builder)
    stamp_path = stamps_dir() / f"{name}.json"
    stamp = json.loads(stamp_path.read_text()) if stamp_path.exists() else {}
    if stamp.get("fingerprint") == current and still_valid(name, recipe, stamp, manifest):
        return f"up to date ({stamp['source']})"
    for out in recipe["outputs"]:
        check_replaceable(out)

    entry = None
    if manifest and manifest.get("cache") and not edited:
        key = build.cache_key(name, recipe, ids, builder["id"])
        candidate = Path(manifest["cache"]) / "builds" / name / key
        if os.path.lexists(candidate):
            if not build.verify_entry(candidate, key, recipe):
                raise Refused(f"cache entry {candidate} exists but does not verify; not using "
                              "or rebuilding over it — report it to the session owner")
            entry = (key, candidate)

    stamp_path.parent.mkdir(parents=True, exist_ok=True)
    stamp_path.unlink(missing_ok=True)  # from here on no stamp vouches for the old outputs
    for out in recipe["outputs"]:
        remove(REPO / out)
    if entry:
        key, candidate = entry
        for out in recipe["outputs"]:
            (REPO / out).parent.mkdir(parents=True, exist_ok=True)
            os.symlink(candidate / "files" / out, REPO / out)
        how = f"cache {key}"
    else:
        key = None
        for sm in recipe["submodules"]:
            if not (REPO / sm / ".git").exists():  # never reset a checked-out submodule's edits
                git(REPO, "submodule", "update", "--init", "--", sm)
        log = stamp_path.with_suffix(".log")
        with open(log, "w") as out_log:
            rc = subprocess.run(["bash", "-c", recipe["command"]], cwd=REPO,
                                stdout=out_log, stderr=subprocess.STDOUT).returncode
        if rc != 0:
            raise Refused(f"local build failed (exit {rc}); log: {log}")
        how = "local build (inputs edited)" if edited else "local build (no cache entry)"
    outputs = {out: output_state(out) for out in recipe["outputs"]}
    bad = {out: s["type"] for out, s in outputs.items() if s["type"] not in ("file", "dir", "symlink")}
    if bad:
        raise Refused(f"outputs missing or of the wrong type after staging: {bad}")
    stamp_path.write_text(json.dumps({"fingerprint": current, "source": "cache" if entry else "local",
                                      "key": key, "outputs": outputs}, indent=2) + "\n")
    return how


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--component", action="append", choices=sorted(build.RECIPES))
    args = parser.parse_args()
    try:
        manifest = trusted_manifest()
        if manifest is None:
            print("no launcher manifest ($MINERVA_NATIVES_MANIFEST): building locally", file=sys.stderr)
        for name in args.component or list(build.RECIPES):
            print(f"[{name}] {stage(name, manifest)}", flush=True)
    except (Refused, subprocess.CalledProcessError, SystemExit) as e:
        detail = e.stderr.decode().strip() if isinstance(e, subprocess.CalledProcessError) else e
        print(f"dev-natives refused: {detail}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
