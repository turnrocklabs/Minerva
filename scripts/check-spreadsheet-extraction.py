#!/usr/bin/env python3
"""Guard the retired host implementation; the plugin owns its dependency census."""
import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


DOMAIN = re.compile(r"\b(?:SpreadsheetEditor|SpreadsheetData|SpreadsheetCell|SpreadsheetHistory|"
                    r"SpreadsheetChart|FormulaEngine|ExcelHandler|SpreadsheetFileHandler|"
                    r"find_spreadsheet|LinkedSpreadsheet)\b|\.spreadsheet_editor\b|\bType\.SPREADSHEET\b")
# These are opaque saved-data fields, never spreadsheet behavior. Remove only
# after an owner-approved end to pre-plugin session/note support.
LEGACY_LINES = {
    "src/Scripts/UI/Controls/Note.gd": {
        'note_data["LinkedSpreadsheet"] = linked_spreadsheet',
        'note.linked_spreadsheet = note_data.get("LinkedSpreadsheet", "")',
    },
}
# Presentation consumes the same public icon UID after its B4 relocation.
SHARED_ASSETS = {"src/assets/icons/spreadsheet_icon_white_no_bg_24.png",
                 "src/assets/icons/spreadsheet_icon_white_no_bg_24.png.import"}


def blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def violations(root: Path) -> list[str]:
    findings: list[str] = []
    inventory = root / "tests/fixtures/spreadsheet-extraction-inventory.tsv"
    if hashlib.sha256(inventory.read_bytes()).hexdigest() != "3b29ce3dc855d2ba7e36003716ec2104c61da959c274bc9507d17bdd714f2a8a":
        return ["B4 disposition inventory changed: reconcile its authority before changing the gate"]
    with inventory.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    for row in rows:
        path = root / row["path"]
        if row["disposition"] == "delete-after-replacement" and path.exists():
            findings.append(f"{row['path']}: retired implementation returned")
        if row["disposition"] == "keep-frozen":
            if not path.is_file() or blob(path.read_bytes()) != row["git_blob"]:
                findings.append(f"{row['path']}: frozen B0 oracle changed or missing")
    for directory in ("src/Scripts", "src/Scenes"):
        for path in sorted((root / directory).rglob("*")):
            if path.suffix not in (".gd", ".tscn", ".tres"):
                continue
            name = path.relative_to(root).as_posix()
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if DOMAIN.search(line) and line.strip() not in LEGACY_LINES.get(name, set()):
                    findings.append(f"{name}:{number}: retired spreadsheet implementation reference")
    for path in sorted((root / "src/assets").rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_file() and "spreadsheet" in name.lower() and name not in SHARED_ASSETS:
            findings.append(f"{name}: unledgered spreadsheet asset")
    fixture = root / "src/test/fixtures/spreadsheet_contract/tools.json"
    legacy_tools = {tool["name"] for tool in json.loads(fixture.read_text(encoding="utf-8"))}
    for path in sorted((root / "src/Data").glob("*.dct")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            item = json.loads(line)
            if item.get("type") == "skill":
                names = set(re.findall(r"\bminerva_\w+\b", json.dumps(item)))
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
        result = subprocess.run([sys.executable, str(args.plugins.resolve() / "sheets/scripts/check-private-imports.py"),
                                 str(root), "--self-test"], check=False)
        if result.returncode:
            return result.returncode
    print("PASS spreadsheet extraction boundary (B4 inventory, frozen oracles, runtime references, assets, skills)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
