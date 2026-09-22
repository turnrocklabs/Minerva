#!/usr/bin/env python3
"""No-clobber publishing and tree integrity for the container test caches.

Used by scripts/container-test.sh (via this CLI) and scripts/container-build/
build.py (by import). Linux only. Nothing here deletes or replaces anything:

  publish_tree(src, dst) renames src to dst with renameat2(RENAME_NOREPLACE),
  which the kernel refuses when dst exists — unlike rename(2), which silently
  replaces a file or empty directory. There is no fallback: a libc without
  renameat2, a filesystem without RENAME_NOREPLACE, or a cross-device move is
  an error. On any refusal the destination's contents and metadata are
  unchanged and the staged source is kept — though publish_tree has already
  made the source's permission bits read-only.

  Symlink policy (tree_problem): a link inside a published tree must be
  relative and resolve, hop by hop, to an existing non-link entry inside the
  tree — so a library link like libfoo.so -> libfoo.so.1 is fine, and nothing
  can point out of the cache.

  tree_digest(path) hashes a tree without following symlinks: every relative
  name, its type, file bytes and executable bit, link text, and empty
  directories. Two trees with the same digest are equivalent for our use.

CLI (exit 0 success, 3 refused/mismatch, 2 usage):
  publish.py publish SRC DST       stage-to-cache publish; an existing DST is
                                   accepted only if its digest equals SRC's
                                   (SRC is then kept and reported)
  publish.py digest PATH           print tree_digest(PATH)
  publish.py check PATH DIGEST     exit 0 only if tree_digest(PATH) == DIGEST
  publish.py check-git PATH REPO SHA
                                   exit 0 only if PATH holds exactly
                                   `git archive SHA` (paths, modes, blob ids;
                                   assumes no export-ignore/export-subst
                                   attributes — none are set in this repo)
These assume nothing else mutates the cache concurrently.
"""
import ctypes
import errno
import hashlib
import json
import os
import stat
import subprocess
import sys

AT_FDCWD = -100
RENAME_NOREPLACE = 1


class PublishError(Exception):
    """Publishing refused or failed; the destination is unchanged."""


def entry_type(root: str, rel: str) -> str:
    """Type of root/rel ("file", "dir", "symlink", "other"), walking each
    component with lstat and refusing to pass through a symlink or a
    non-directory; "missing" if absent, "blocked" if an ancestor is not a
    real directory. root itself must be a real directory ("blocked" if not)."""
    path = root
    try:
        if not stat.S_ISDIR(os.lstat(root).st_mode):
            return "blocked"
        parts = [p for p in rel.split("/")]
        if not parts or any(p in ("", ".", "..") for p in parts):
            return "blocked"
        for part in parts[:-1]:
            path = os.path.join(path, part)
            if not stat.S_ISDIR(os.lstat(path).st_mode):
                return "blocked"
        mode = os.lstat(os.path.join(path, parts[-1])).st_mode
    except FileNotFoundError:
        return "missing"
    return ("symlink" if stat.S_ISLNK(mode) else "dir" if stat.S_ISDIR(mode)
            else "file" if stat.S_ISREG(mode) else "other")


def tree_problem(root: str) -> str:
    """"" if every symlink under root follows the policy above, else why not."""
    for rel, kind, *rest in tree_manifest(root):
        if kind != "symlink":
            continue
        current = rel
        for _ in range(8):  # a longer chain is refused
            text = os.readlink(os.path.join(root, current))
            if os.path.isabs(text):
                return f"{rel}: absolute symlink {text}"
            target = os.path.normpath(os.path.join(os.path.dirname(current), text))
            if target == ".." or target.startswith("../") or target == ".":
                return f"{rel}: symlink leaves the tree ({text})"
            kind = entry_type(root, target)
            if kind in ("file", "dir"):
                break
            if kind != "symlink":
                return f"{rel}: symlink target {target} is {kind}"
            current = target
        else:
            return f"{rel}: symlink chain too long"
    return ""


def rename_noreplace(src: str, dst: str) -> str:
    """Atomically rename src to dst unless dst exists. Returns "published" or
    "exists"; raises PublishError for anything else. Never falls back."""
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameat2 = libc.renameat2
    except AttributeError:
        raise PublishError("libc has no renameat2; refusing to publish (no fallback)")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    if renameat2(AT_FDCWD, os.fsencode(src), AT_FDCWD, os.fsencode(dst), RENAME_NOREPLACE) == 0:
        return "published"
    err = ctypes.get_errno()
    if err == errno.EEXIST:
        return "exists"
    if err in (errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP):
        raise PublishError(f"RENAME_NOREPLACE unsupported here ({errno.errorcode[err]}); refusing, "
                           f"{src} kept")
    raise PublishError(f"rename {src} -> {dst} failed: {os.strerror(err)} "
                       f"({errno.errorcode.get(err, err)}); {src} kept")


def make_read_only(path: str, keep_top_writable: bool) -> None:
    """chmod a-w a tree we staged, never through symlinks. The top directory
    may keep u+w: moving a directory to a new parent needs its own write bit."""
    for dirpath, dirnames, filenames in os.walk(path, topdown=False, followlinks=False):
        for name in filenames + dirnames:
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            if not stat.S_ISLNK(st.st_mode):
                os.chmod(full, stat.S_IMODE(st.st_mode) & ~0o222)
    st = os.lstat(path)
    if not stat.S_ISLNK(st.st_mode):
        mode = stat.S_IMODE(st.st_mode) & ~0o222
        os.chmod(path, mode | 0o200 if keep_top_writable and stat.S_ISDIR(st.st_mode) else mode)


def publish_tree(src: str, dst: str) -> str:
    """Make src read-only and rename it to dst without replacing anything.
    Returns "published" or "exists" (dst untouched, src kept)."""
    st = os.lstat(src)
    if stat.S_ISLNK(st.st_mode):
        raise PublishError(f"refusing to publish a symlink: {src}")
    make_read_only(src, keep_top_writable=True)
    result = rename_noreplace(src, dst)
    if result == "published" and stat.S_ISDIR(st.st_mode):
        os.chmod(dst, stat.S_IMODE(os.lstat(dst).st_mode) & ~0o222)  # the entry we just placed
    return result


def tree_manifest(path: str) -> list:
    """Sorted entries (relative name, type, content) without following links."""
    entries = []

    def visit(full: str, rel: str) -> None:
        st = os.lstat(full)
        if stat.S_ISLNK(st.st_mode):
            entries.append([rel, "symlink", os.readlink(full)])
        elif stat.S_ISREG(st.st_mode):
            with open(full, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            entries.append([rel, "file", digest, bool(st.st_mode & 0o111)])
        elif stat.S_ISDIR(st.st_mode):
            entries.append([rel, "dir"])
            for child in sorted(os.listdir(full)):
                visit(os.path.join(full, child), f"{rel}/{child}" if rel else child)
        else:
            entries.append([rel, "other", stat.S_IFMT(st.st_mode)])

    visit(path, "")
    return entries


def tree_digest(path: str) -> str:
    return hashlib.sha256(json.dumps(tree_manifest(path)).encode()).hexdigest()


def _ancestors(rel: str) -> list:
    parts = rel.split("/") if rel else []
    return ["/".join(parts[:i]) for i in range(1, len(parts))]


def git_tree_matches(path: str, repo: str, sha: str) -> tuple[bool, str]:
    """Does path hold exactly what `git archive sha` produces? Compares every
    path, mode (file/exec/symlink/gitlink dir) and blob id against ls-tree."""
    listing = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", "--full-tree", sha],
                             check=True, capture_output=True).stdout
    expected = {}
    for record in listing.split(b"\0"):
        if record:
            meta, name = record.split(b"\t", 1)
            mode, _, blob = meta.decode().split()
            expected[os.fsdecode(name)] = (mode, blob if mode != "160000" else "")
    # Directories git archive creates: every file's ancestors.
    expected_dirs = {os.path.dirname(name) for name in expected}
    expected_dirs |= {d for name in list(expected_dirs) for d in _ancestors(name)}
    actual, files = {}, []
    for rel, kind, *rest in tree_manifest(path):
        if kind == "file":
            actual[rel] = ("100755" if rest[1] else "100644", None)
            files.append(rel)
        elif kind == "symlink":
            actual[rel] = ("120000", None)
            files.append(rel)
        elif kind == "dir" and rel and expected.get(rel, ("",))[0] == "160000":
            actual[rel] = ("160000", "")  # git archive leaves a submodule as an empty dir
        elif kind == "dir" and rel and rel not in expected_dirs:
            return False, f"extra directory {rel}"
        elif kind == "other":
            return False, f"unexpected file type at {rel}"
    if any("\n" in f for f in files):
        return False, "a file name contains a newline"
    if files:  # git's own blob ids, hashed from the files as they are (links as link text)
        ids = subprocess.run(["git", "-C", repo, "hash-object", "--no-filters", "--stdin-paths"],
                             input="\n".join(os.path.join(path, f) for f in files if actual[f][0] != "120000"),
                             check=True, capture_output=True, text=True).stdout.split()
        regular = [f for f in files if actual[f][0] != "120000"]
        for rel, blob in zip(regular, ids):
            actual[rel] = (actual[rel][0], blob)
        for rel in files:
            if actual[rel][0] == "120000":
                text = os.readlink(os.path.join(path, rel)).encode()
                actual[rel] = ("120000", hashlib.sha1(b"blob %d\0" % len(text) + text).hexdigest())
    if actual != expected:
        missing = sorted(set(expected) - set(actual))[:3]
        extra = sorted(set(actual) - set(expected))[:3]
        changed = sorted(k for k in set(actual) & set(expected) if actual[k] != expected[k])[:3]
        return False, f"missing {missing} extra {extra} changed {changed}"
    return True, ""


def main(argv: list) -> int:
    try:
        if len(argv) == 4 and argv[1] == "publish":
            src, dst = argv[2], argv[3]
            if publish_tree(src, dst) == "published":
                print(f"published {dst}")
                return 0
            if tree_digest(dst) == tree_digest(src):
                print(f"{dst} already published identically; kept staged copy at {src}")
                return 0
            print(f"refused: {dst} exists and differs from the staged copy; left both "
                  f"({src} kept)", file=sys.stderr)
            return 3
        if len(argv) == 3 and argv[1] == "digest":
            print(tree_digest(argv[2]))
            return 0
        if len(argv) == 4 and argv[1] == "check":
            if tree_digest(argv[2]) == argv[3]:
                return 0
            print(f"refused: {argv[2]} does not match digest {argv[3]}", file=sys.stderr)
            return 3
        if len(argv) == 5 and argv[1] == "check-git":
            good, why = git_tree_matches(argv[2], argv[3], argv[4])
            if good:
                return 0
            print(f"refused: {argv[2]} is not git archive {argv[4]}: {why}", file=sys.stderr)
            return 3
    except (PublishError, OSError, subprocess.CalledProcessError) as e:
        print(f"refused: {e}", file=sys.stderr)
        return 3
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
