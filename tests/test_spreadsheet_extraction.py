"""Real file mutations of the extraction gate; run in a disposable container."""
import csv
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("extraction_gate", ROOT / "scripts/check-spreadsheet-extraction.py")
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ExtractionGateTests(unittest.TestCase):
    def fixture(self) -> Path:
        # The enclosing container owns cleanup; tests never delete a supplied tree.
        root = Path(tempfile.mkdtemp(prefix="extraction-gate-"))
        ledger = "tests/fixtures/spreadsheet-extraction-inventory.tsv"
        with (ROOT / ledger).open(encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream, delimiter="\t"))
        for name in [ledger] + [row["path"] for row in rows if row["disposition"] == "keep-frozen"]:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        (root / "src/Data").mkdir(parents=True)
        self.assertEqual(GATE.violations(root), [])
        return root

    def test_retired_file(self) -> None:
        root = self.fixture()
        path = root / "src/Scenes/SpreadsheetEditor.tscn"
        path.parent.mkdir(parents=True)
        path.write_text("[gd_scene format=3]\n")
        self.assertTrue(any("retired implementation returned" in value for value in GATE.violations(root)))

    def test_runtime_reference(self) -> None:
        root = self.fixture()
        path = root / "src/Scripts/probe.gd"
        path.parent.mkdir(parents=True)
        path.write_text("extends RefCounted\nvar bad: SpreadsheetEditor\n")
        self.assertTrue(any("implementation reference" in value for value in GATE.violations(root)))

    def test_all_retired_classes_outside_scripts(self) -> None:
        root = self.fixture()
        with (root / "tests/fixtures/spreadsheet-extraction-inventory.tsv").open() as stream:
            names = [row["retired_class"] for row in csv.DictReader(stream, delimiter="\t") if row["retired_class"]]
        self.assertEqual(len(names), 20)
        path = root / "src/resources/neutral.gd"
        path.parent.mkdir(parents=True)
        for name in names:
            with self.subTest(name=name):
                path.write_text("extends RefCounted\nvar bad: " + name + "\n")
                self.assertTrue(any("implementation reference" in value for value in GATE.violations(root)))

    def test_dangling_retired_uid(self) -> None:
        root = self.fixture()
        path = root / "src/Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetData.gd.uid"
        path.parent.mkdir(parents=True)
        path.symlink_to("absent-target")
        self.assertTrue(any("retired implementation returned" in value for value in GATE.violations(root)))

    def test_named_saved_data_fields_and_fixtures(self) -> None:
        root = self.fixture()
        path = root / "src/Scripts/UI/Controls/Note.gd"
        path.parent.mkdir(parents=True)
        path.write_text('note_data["LinkedSpreadsheet"] = linked_spreadsheet\n')
        (root / "src/test/fixture.gd").write_text("var legacy: SpreadsheetEditor\n")
        self.assertEqual(GATE.violations(root), [])

    def test_unledgered_asset(self) -> None:
        root = self.fixture()
        path = root / "src/assets/icons/spreadsheet/unledgered.svg"
        path.parent.mkdir(parents=True)
        path.write_text("<svg/>\n")
        self.assertTrue(any("unledgered spreadsheet artifact" in value for value in GATE.violations(root)))

    def test_shipped_skill_legacy_tool(self) -> None:
        for prefix in ["Instructions:\n", "\t"]:
            with self.subTest(prefix=repr(prefix)):
                root = self.fixture()
                tools = json.loads((root / "src/test/fixtures/spreadsheet_contract/tools.json").read_text())
                tool = tools[0]["name"]
                (root / "src/Data/master.dct").write_text(json.dumps({"type": "skill", "tool_deps": [prefix + tool]}) + "\n")
                self.assertTrue(any("legacy skill tool " + tool in value for value in GATE.violations(root)))

    def test_triple_quoted_string_before_reference(self) -> None:
        root = self.fixture()
        path = root / "src/resources/neutral.gd"
        path.parent.mkdir(parents=True)
        for value in ['var probe = ["""a"#b""", SpreadsheetEditor]\n',
                      'var text = """first\n"#inside\nlast"""\nvar bad: SpreadsheetEditor\n']:
            with self.subTest(value=value):
                path.write_text(value)
                self.assertTrue(any("implementation reference" in item for item in GATE.violations(root)))

    def test_asset_outside_asset_directory(self) -> None:
        root = self.fixture()
        path = root / "src/resources/spreadsheet_new.svg"
        path.parent.mkdir(parents=True)
        path.write_text("<svg/>\n")
        self.assertTrue(any("unledgered spreadsheet artifact" in value for value in GATE.violations(root)))

    def test_runtime_comments_are_rejected(self) -> None:
        for suffix, comment in [(".gd", "#"), (".tscn", ";"), (".tres", ";")]:
            with self.subTest(suffix=suffix):
                root = self.fixture()
                path = root / ("src/resources/neutral" + suffix)
                path.parent.mkdir(parents=True)
                path.write_text(comment + " SpreadsheetEditor was retired\n")
                self.assertTrue(any("implementation reference" in value for value in GATE.violations(root)))

    def test_missing_ledger_row(self) -> None:
        root = self.fixture()
        (root / "tests/fixtures/spreadsheet-extraction-inventory.tsv").write_text("disposition\tpath\tgit_blob\tbase\n")
        self.assertTrue(any("disposition inventory changed" in value for value in GATE.violations(root)))

    def test_frozen_oracle(self) -> None:
        root = self.fixture()
        (root / "src/test/fixtures/spreadsheet_contract/sample.csv").write_text("changed\n")
        self.assertTrue(any("frozen B0 oracle" in value for value in GATE.violations(root)))


if __name__ == "__main__":
    unittest.main()
