#!/usr/bin/env python3
"""Acquire verified jsoncons source and build Minerva's standalone helper."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
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
    cache.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        with urllib.request.urlopen(URL) as source, archive.open("wb") as target:
            shutil.copyfileobj(source, target)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != SHA256:
        raise SystemExit(f"jsoncons archive hash mismatch: {actual}")
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
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
    (destination / "MINERVA_SOURCE_PROVENANCE").write_text(
        f"jsoncons {COMMIT} ({SHA256}), Boost-1.0; Minerva integral multipleOf patch\n",
        encoding="utf-8")
    apply_integral_multiple_of_policy(root, destination)
    (destination / ".gdignore").touch()
    return destination / "include"


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
