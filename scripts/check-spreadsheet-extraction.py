#!/usr/bin/env python3
"""Guard the retired host implementation; the plugin owns its dependency census."""
import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

# These are opaque saved-data fields, never spreadsheet behavior. Remove only
# after an owner-approved end to pre-plugin session/note support.
LEGACY_LINES = {
    "src/Scripts/UI/Controls/Note.gd": {
        'note_data["LinkedSpreadsheet"] = linked_spreadsheet',
        'note.linked_spreadsheet = note_data.get("LinkedSpreadsheet", "")',
    },
}
RUNTIME_EXCLUSIONS = ("src/test", "src/.godot")
# Opaque compatibility/recovery resources; Presentation retains the relocated icon UID.
ALLOWED_ARTIFACTS = {"src/Scripts/Services/Plugins/SpreadsheetSession.gd",
                    "src/Scripts/Services/Plugins/LegacySpreadsheetNote.gd",
                    "src/Scripts/UI/Controls/SpreadsheetRecovery.gd",
                    "src/Scenes/SpreadsheetRecovery.tscn",
                    "src/assets/icons/spreadsheet_icon_white_no_bg_24.png",
                 "src/assets/icons/spreadsheet_icon_white_no_bg_24.png.import"}


def blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def string_values(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from string_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from string_values(child)


def violations(root: Path) -> list[str]:
    findings: list[str] = []
    inventory = root / "tests/fixtures/spreadsheet-extraction-inventory.tsv"
    if hashlib.sha256(inventory.read_bytes().replace(b"\r\n", b"\n")).hexdigest() != "84aa3cc7bd9d7d00ca138878c75c75a44d587a769b0c93c1413eb644c8bf15b6":
        return ["B4 disposition inventory changed: reconcile its authority before changing the gate"]
    with inventory.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    retired = [re.escape(row["retired_class"]) for row in rows if row["retired_class"]]
    domain = re.compile(r"\b(?:" + "|".join(retired + ["find_spreadsheet", "LinkedSpreadsheet"])
                        + r")\b|\.spreadsheet_editor\b|\bType\.SPREADSHEET\b")
    for row in rows:
        path = root / row["path"]
        if row["disposition"] == "delete-after-replacement" and (path.exists() or path.is_symlink()):
            findings.append(f"{row['path']}: retired implementation returned")
        if row["disposition"] == "keep-frozen" and (not path.is_file() or blob(path.read_bytes()) != row["git_blob"]):
            findings.append(f"{row['path']}: frozen B0 oracle changed or missing")
    for path in sorted((root / "src").rglob("*")):
        if any(path.is_relative_to(root / excluded) for excluded in RUNTIME_EXCLUSIONS):
            continue
        name = path.relative_to(root).as_posix()
        if path.is_file() and "spreadsheet" in name.lower() and name.removesuffix(".uid") not in ALLOWED_ARTIFACTS:
            findings.append(f"{name}: unledgered spreadsheet artifact")
        if path.suffix not in (".gd", ".tscn", ".tres"):
            continue
        for number, code in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if domain.search(code) and code.strip() not in LEGACY_LINES.get(name, set()):
                findings.append(f"{name}:{number}: retired spreadsheet implementation reference")
    fixture = root / "src/test/fixtures/spreadsheet_contract/tools.json"
    legacy_tools = {tool["name"] for tool in json.loads(fixture.read_text(encoding="utf-8"))}
    for path in sorted((root / "src/Data").glob("*.dct")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            item = json.loads(line)
            if item.get("type") == "skill":
                names = {name for value in string_values(item) for name in re.findall(r"\bminerva_\w+\b", value)}
                for name in sorted(names & legacy_tools):
                    findings.append(f"{path.relative_to(root)}:{number}: legacy skill tool {name}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugins", type=Path,
                        help="explicit plugin checkout: also run its existing packaged-resource census")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    findings = violations(root)
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        return 1
    if args.plugins is not None:
        result = subprocess.run([sys.executable, "-B", str(args.plugins.resolve() / "sheets/scripts/check-private-imports.py"),
                                 str(root), "--self-test"], check=False)
        if result.returncode:
            return result.returncode
    print("PASS spreadsheet extraction boundary (B4 inventory, frozen oracles, runtime references, assets, skills)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
