#!/usr/bin/env python3
"""Prepare a separate Godot editor bundle with Minerva's Bluetooth purpose string."""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def bluetooth_usage(presets_text: str) -> str:
    """Read the purpose string from the macOS export's additional plist XML."""
    parts = re.split(r"(?m)^\[([^\]]+)\]\s*$", presets_text)
    sections = dict(zip(parts[1::2], parts[2::2]))
    presets = [name for name, body in sections.items()
               if re.search(r'(?m)^platform="macOS"$', body)]
    if len(presets) != 1:
        raise ValueError("expected exactly one macOS export preset")
    options = sections[presets[0] + ".options"]
    matches = re.findall(r"(?m)^application/additional_plist_content=(.+)$", options)
    if len(matches) != 1:
        raise ValueError("expected one additional_plist_content value in the macOS preset")
    fragment = json.loads(matches[0])
    metadata = plistlib.loads((f'<plist version="1.0"><dict>{fragment}</dict></plist>').encode())
    usage = metadata.get("NSBluetoothAlwaysUsageDescription")
    if not isinstance(usage, str) or not usage.strip():
        raise ValueError("macOS export must declare a nonempty Bluetooth purpose string")
    return usage


def prepare_editor(source: Path, destination: Path, usage: str) -> None:
    """Copy and sign an editor without altering or launching the installed app."""
    source = source.expanduser().resolve(strict=True)
    destination = destination.expanduser()
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"destination already exists: {destination}")
    destination = destination.resolve()
    if destination.suffix != ".app" or source in destination.parents:
        raise ValueError("destination must be a separate .app outside the source bundle")
    source_plist = source / "Contents/Info.plist"
    source_binary = source / "Contents/MacOS/Godot"
    if any(path.is_symlink() for path in (source / "Contents", source / "Contents/MacOS",
                                         source_plist, source_binary)) or not source_binary.is_file():
        raise ValueError("source must be a Godot.app with regular plist and executable files")
    metadata = plistlib.loads(source_plist.read_bytes())
    if metadata.get("CFBundleIdentifier") != "org.godotengine.godot":
        raise ValueError("source must have the official Godot editor bundle identifier")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)

    # Reserve a fresh destination; an interrupted run remains visible for inspection.
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir()
    # This locally rebuilt copy must not inherit the downloaded app's quarantine.
    subprocess.run(["ditto", "--noqtn", str(source), str(destination)], check=True)
    metadata["NSBluetoothAlwaysUsageDescription"] = usage
    (destination / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
    # Keep the upstream entitlements and hardened-runtime flags, adding no permissions.
    subprocess.run(["codesign", "--force", "--sign", "-",
                    "--preserve-metadata=entitlements,flags,runtime", str(destination)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
    print(f"Prepared {destination}; Bluetooth purpose: {usage}")
    print("The copy is ad-hoc signed; macOS may ask for permissions again.")
    print(f"Editor executable: {destination / 'Contents/MacOS/Godot'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="installed Godot.app to copy")
    parser.add_argument("destination", type=Path, help="new .app path; must not exist")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("preparing an editor requires macOS codesign and ditto")
    presets = Path(__file__).resolve().parents[1] / "src/export_presets.cfg"
    try:
        prepare_editor(args.source, args.destination, bluetooth_usage(presets.read_text()))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot prepare editor: {error}\n")


if __name__ == "__main__":
    main()
