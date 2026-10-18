"""Packaged probes keep each repository's captured release pages separate."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("packaged_probe", ROOT / "scripts/verify-packaged-mcp-app.py")
assert SPEC is not None and SPEC.loader is not None
PROBE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class RequiredSnapshotTest(unittest.TestCase):
    def test_repository_paths_paging_and_refusals(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "releases.json"
            snapshot.write_text(json.dumps({"owner-a/catalog-a": [[{"tag_name": "first"}], [{"tag_name": "second"}]],
                                            "owner-b/catalog-b": [[{"tag_name": "independent"}]]}))
            before = os.environ.get("MINERVA_REQUIRED_RELEASES_JSON")
            os.environ["MINERVA_REQUIRED_RELEASES_JSON"] = str(snapshot)
            try:
                with PROBE._required_releases() as base:
                    for path, expected in [("owner-a/catalog-a/releases?per_page=1&page=2", "second"),
                                           ("owner-b/catalog-b/releases?per_page=1&page=1", "independent")]:
                        with urlopen(f"{base}/repos/{path}", timeout=2) as response:
                            self.assertEqual(json.load(response), [{"tag_name": expected}])
                    for path, status in [("repos/other/catalog/releases", 404), ("required-releases.json", 400),
                                         ("repos/owner-a/catalog-a/releases?page=0", 400)]:
                        with self.assertRaises(HTTPError) as error:
                            urlopen(f"{base}/{path}", timeout=2)
                        self.assertEqual(error.exception.code, status)
                for invalid in [[], {"owner-a/catalog-a": [{}]}, {"wrong": [[]]}]:
                    snapshot.write_text(json.dumps(invalid))
                    with self.assertRaises(ValueError), PROBE._required_releases():
                        self.fail("invalid snapshot accepted")
            finally:
                if before is None:
                    os.environ.pop("MINERVA_REQUIRED_RELEASES_JSON", None)
                else:
                    os.environ["MINERVA_REQUIRED_RELEASES_JSON"] = before


if __name__ == "__main__":
    unittest.main()
