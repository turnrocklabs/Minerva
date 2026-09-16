#!/usr/bin/env python3
"""Acquire verified jsoncons source and build Minerva's standalone helper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

COMMIT = "bcb44594c50c495ee1e690602cdd71455942ad0e"
SHA256 = "44742915ad9fa93fa33680be56cadd77ee2c81c2740d790f538a93c084fe6f6a"
PATCH_SHA256 = "ca0bbbd45e7e0e3e60ca68efb3f9467efb1aebddcd58dd4027230a76801b6ce3"
URL = f"https://github.com/danielaparker/jsoncons/archive/{COMMIT}.tar.gz"


def apply_integral_multiple_of_policy(root: Path, destination: Path) -> None:
    """Remove jsoncons' ULP tolerance for our integral-only multipleOf subset."""
    header = destination / "include/jsoncons_ext/jsonschema/common/keyword_validator.hpp"
    old = """            double rem = std::remainder(x, multiple_of);
            double eps = std::nextafter(x, 0) - x;
            return std::fabs(rem) < std::fabs(eps);"""
    new = """            return std::fmod(x, multiple_of) == 0.0;"""
    source = header.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit("pinned jsoncons multipleOf implementation changed")
    header.write_text(source.replace(old, new), encoding="utf-8")
    factory = destination / "include/jsoncons_ext/jsonschema/common/keyword_validator_factory.hpp"
    factory_source = factory.read_text(encoding="utf-8")
    include_old = "#include <cstddef>"
    include_new = "#include <cmath>\n#include <cstddef>"
    factory_old = """            auto value = sch.template as<double>();
            return jsoncons::make_unique<multiple_of_validator<Json>>(parent, schema_location, 
                context.get_custom_message("multipleOf"), value);"""
    factory_new = """            auto value = sch.template as<double>();
            if (!std::isfinite(value) || value <= 0.0)
            {
                JSONCONS_THROW(schema_error(schema_location.string() +
                    ": [minerva_invalid_schema] multipleOf must be positive"));
            }
            if (std::trunc(value) != value ||
                    std::fabs(value) > 9007199254740991.0)
            {
                JSONCONS_THROW(schema_error(schema_location.string() +
                    ": [minerva_unsupported_number] multipleOf must be a safe-range integer"));
            }
            return jsoncons::make_unique<multiple_of_validator<Json>>(parent, schema_location, 
                context.get_custom_message("multipleOf"), value);"""
    if factory_source.count(include_old) != 1 or factory_source.count(factory_old) != 1:
        raise SystemExit("pinned jsoncons multipleOf factory changed")
    factory.write_text(factory_source.replace(include_old, include_new, 1).replace(
        factory_old, factory_new), encoding="utf-8")
    patch = root / "src/native/json_schema_helper/jsoncons-integral-multiple-of.patch"
    if not patch.is_file():
        raise SystemExit("missing documented jsoncons compatibility patch")
    if hashlib.sha256(patch.read_bytes()).hexdigest() != PATCH_SHA256:
        raise SystemExit("jsoncons compatibility patch hash mismatch")


def acquire(root: Path) -> Path:
    cache = Path(os.environ.get("MINERVA_DEPENDENCY_CACHE", root / ".dependency-cache"))
    archive = cache / f"jsoncons-{COMMIT}.tar.gz"
    destination = root / "src/native/vendor/jsoncons"
    stamp = destination / "MINERVA_BUILD_INPUTS.json"
    patch = root / "src/native/json_schema_helper/jsoncons-integral-multiple-of.patch"
    if hashlib.sha256(patch.read_bytes()).hexdigest() != PATCH_SHA256:
        raise SystemExit("jsoncons compatibility patch hash mismatch")
    if stamp.is_file():
        saved = json.loads(stamp.read_text(encoding="utf-8"))
        if saved == {"archive": SHA256, "patch": PATCH_SHA256,
                     "headers": header_hashes(destination)}:
            print("Verified jsoncons headers already current")
            return destination / "include"
        raise SystemExit(f"jsoncons inputs changed in {destination}. Preserve any local edits, "
                         "then move that generated directory aside and rerun to reacquire it.")
    if destination.exists():
        raise SystemExit(f"Unverified jsoncons tree at {destination}. Move it aside and rerun "
                         "to acquire verified sources; local files will not be overwritten.")
    cache.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=cache) as download_dir:
            download = Path(download_dir) / archive.name
            with urllib.request.urlopen(URL, timeout=60) as source, download.open("wb") as target:
                shutil.copyfileobj(source, target)
            if hashlib.sha256(download.read_bytes()).hexdigest() != SHA256:
                raise SystemExit("downloaded jsoncons archive hash mismatch")
            download.replace(archive)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != SHA256:
        raise SystemExit(f"jsoncons archive hash mismatch: {actual}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as staging_dir:
        staged = Path(staging_dir) / "jsoncons"
        staged.mkdir()
        extract_source(archive, staged)
        (staged / "MINERVA_SOURCE_PROVENANCE").write_text(
            f"jsoncons {COMMIT} ({SHA256}), Boost-1.0; Minerva integral multipleOf patch\n",
            encoding="utf-8")
        apply_integral_multiple_of_policy(root, staged)
        (staged / ".gdignore").touch()
        (staged / stamp.name).write_text(json.dumps({
            "archive": SHA256, "patch": PATCH_SHA256, "headers": header_hashes(staged)
        }, sort_keys=True), encoding="utf-8")
        staged.rename(destination)
    return destination / "include"


def header_hashes(destination: Path) -> dict:
    return {str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((destination / "include").rglob("*")) if path.is_file()}


def extract_source(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, "r:gz") as bundle:
        prefix = f"jsoncons-{COMMIT}/"
        for member in bundle.getmembers():
            if member.name.rstrip("/") == f"jsoncons-{COMMIT}":
                if not member.isdir():
                    raise SystemExit("jsoncons archive root is not a directory")
                continue
            if (not member.name.startswith(prefix) or ".." in Path(member.name).parts
                    or member.issym() or member.islnk()
                    or not (member.isdir() or member.isfile())):
                raise SystemExit("unsafe jsoncons archive path")
            member.name = member.name[len(prefix):]
            if member.name:
                bundle.extract(member, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("linux", "windows", "macos"), required=True)
    parser.add_argument("--acquire-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    include = acquire(root)
    if not args.acquire_only:
        environment = os.environ.copy()
        environment["MINERVA_JSONCONS_INCLUDE"] = str(include)
        subprocess.run(["scons", "-f", "native/json_schema_helper/SConscript",
                       f"platform={args.platform}", "json-schema-helper"],
                       cwd=root / "src", env=environment, check=True)


if __name__ == "__main__":
    main()
