#!/usr/bin/env python3
"""Put a build.zig.zon's URL dependencies into Zig's package cache before
`zig build`, downloading them with curl.

    scripts/zig-prefetch.py path/to/build.zig.zon

Zig 0.15's own fetcher fails through an HTTPS proxy (ziglang/zig#21792), and
agent containers reach the internet only through one. The manifest stays the
one source of truth: each dependency's URL is downloaded with curl, which
honours HTTPS_PROXY, and handed to `zig fetch`, which unpacks it and prints
the package hash it computed. That hash must equal the manifest's `.hash`,
or nothing is trusted and the run fails. Dependencies already in the global
cache (<cache>/p/<hash>) are skipped; `.path` dependencies need nothing.

Only the plain shape `.name = .{ .url = "...", .hash = "..." [, .lazy = true] }`
is read. Anything else is refused rather than guessed.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ENTRY = re.compile(r'\.(@"[^"]+"|[A-Za-z_][\w]*)\s*=\s*\.\{([^{}]*)\}\s*,?')
FIELD = re.compile(r'\.(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|true|false)\s*,?')


class Refused(Exception):
    pass


def dependencies(zon: str) -> dict:
    """{name: {"url", "hash"} or {"path"}} from the manifest's .dependencies."""
    start = re.search(r'\.dependencies\s*=\s*\.\{', zon)
    if not start:
        return {}
    depth, i = 1, start.end()
    while depth and i < len(zon):
        depth += {"{": 1, "}": -1}.get(zon[i], 0)
        i += 1
    # Whole-line comments only: a "//" can sit inside a URL string.
    body = re.sub(r"(?m)^\s*//[^\n]*", "", zon[start.end():i - 1])
    deps, pos = {}, 0
    for m in ENTRY.finditer(body):
        if body[pos:m.start()].strip():
            raise Refused(f"unreadable text in .dependencies: {body[pos:m.start()].strip()[:60]!r}")
        pos = m.end()
        fields, rest = {}, m.group(2)
        for f in FIELD.finditer(rest):
            fields[f.group(1)] = json.loads(f.group(2))
        if FIELD.sub("", rest).strip():
            raise Refused(f"dependency {m.group(1)}: unreadable fields {rest.strip()[:60]!r}")
        if not ({"url", "hash"} <= set(fields) <= {"url", "hash", "lazy"} or set(fields) == {"path"}):
            raise Refused(f"dependency {m.group(1)}: unsupported fields {sorted(fields)}")
        deps[m.group(1)] = fields
    if body[pos:].strip():
        raise Refused(f"unreadable text in .dependencies: {body[pos:].strip()[:60]!r}")
    return deps


def global_cache() -> Path:
    """Zig's global cache directory, from `zig env` (a ZON document in 0.15)."""
    env = subprocess.run(["zig", "env"], capture_output=True, text=True, check=True).stdout
    m = re.search(r'\.global_cache_dir\s*=\s*("(?:[^"\\]|\\.)*")', env)
    if not m:
        raise Refused("`zig env` names no global_cache_dir")
    return Path(json.loads(m.group(1)))


def prefetch(manifest: Path) -> None:
    cache = global_cache()
    for name, dep in dependencies(manifest.read_text()).items():
        if "url" not in dep:
            continue
        if (cache / "p" / dep["hash"]).is_dir():
            print(f"[zig-prefetch] {name}: cached")
            continue
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / dep["url"].rstrip("/").rsplit("/", 1)[-1]
            subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(archive), dep["url"]], check=True)
            got = subprocess.run(["zig", "fetch", str(archive)], capture_output=True, text=True,
                                 check=True).stdout.strip()
        if got != dep["hash"]:
            raise Refused(f"dependency {name}: {dep['url']} unpacked to {got}, "
                          f"but {manifest} pins {dep['hash']}")
        print(f"[zig-prefetch] {name}: fetched {got}")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        prefetch(Path(sys.argv[1]))
    except (Refused, subprocess.CalledProcessError) as e:
        print(f"zig-prefetch refused: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
