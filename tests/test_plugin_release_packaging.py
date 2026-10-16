"""Docket wrapper releases retain the signed upstream application's identity."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("plugin_release", ROOT / "scripts/package-plugin-release.py")
assert SPEC is not None and SPEC.loader is not None
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class DocketReleaseIdentityTest(unittest.TestCase):
    def test_wrapper_uses_signed_lock_and_rejects_another_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = root / "launcher"
            launcher.write_text("#!/usr/bin/env python3\nimport sys\nsys.stderr.write('receipt accepted')\nsys.exit(2)\n")
            launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR)
            receipt = root / "official/app/acquisition.lock.json"
            receipt.parent.mkdir(parents=True)
            receipt.write_text(json.dumps({"Tag": "v0.3.0-rc.30", "Source": "signed-source"}))
            lock = root / "release.lock.json"
            lock.write_text(json.dumps({"tag": "v0.3.0-rc.30"}))
            manifest = {"version": "0.3.0-rc.30.plugin.1",
                        "backend": {"entrypoint": "launcher"}}
            # A real subprocess refusal proves the wrapper passed the receipt gate.
            with self.assertRaisesRegex(SystemExit, "Docket launcher exited 2: receipt accepted"):
                PACKAGE.probe_docket(root, manifest, lock)
            # Matching the wrapper version cannot substitute for the signed app pin.
            receipt.write_text(json.dumps({"Tag": "v0.3.0-rc.30.plugin.1", "Source": "signed-source"}))
            with self.assertRaisesRegex(SystemExit, "receipt does not identify this release"):
                PACKAGE.probe_docket(root, manifest, lock)


if __name__ == "__main__":
    unittest.main()
