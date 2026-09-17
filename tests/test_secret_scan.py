#!/usr/bin/env python3
"""Exercise the shared secret-history wrapper in disposable Git repositories."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SecretHistoryScanTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool_cache = tempfile.TemporaryDirectory(prefix="minerva-gitleaks-cache-")

    @classmethod
    def tearDownClass(cls):
        cls.tool_cache.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="minerva-secret-scan-")
        self.repo = Path(self.directory.name)
        (self.repo / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/scan-secret-history.sh",
                     self.repo / "scripts/scan-secret-history.sh")
        shutil.copy2(ROOT / ".gitleaks.toml", self.repo / ".gitleaks.toml")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email",
                        "fixture@minerva.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name",
                        "Minerva fixture"], check=True)
        (self.repo / "clean.txt").write_text("clean\n", encoding="utf-8")
        self._commit("clean")
        self.clean_base = subprocess.run(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], check=True,
            capture_output=True, text=True).stdout.strip()
        self.scanner = self.repo / "fake-gitleaks"
        self.scanner.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "if os.environ.get('FAKE_SCANNER_ERROR'):\n"
            "    print('sensitive scanner diagnostic')\n"
            "    raise SystemExit(2)\n"
            "raise SystemExit(0)\n",
            encoding="utf-8")
        self.scanner.chmod(0o755)

    def tearDown(self):
        self.directory.cleanup()

    def _commit(self, message):
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", message],
                       check=True)

    def _scan(self, fake=False, arguments=None, **extra_env):
        env = dict(os.environ, MINERVA_DEPENDENCY_CACHE=self.tool_cache.name,
                   **extra_env)
        env.pop("GITLEAKS_BIN", None)
        if fake:
            env["GITLEAKS_BIN"] = str(self.scanner)
        command = [str(self.repo / "scripts/scan-secret-history.sh")]
        command.extend(arguments or ["--all-history"])
        return subprocess.run(command,
                              cwd=self.repo, env=env, capture_output=True, text=True)

    def test_clean_history_passes(self):
        result = self._scan()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_added_then_removed_secret_fails_without_echoing_secret(self):
        secret = "AKIA" + "QWERTYUIOPASDFGH"
        path = self.repo / "removed.txt"
        path.write_text(secret + "\n", encoding="utf-8")
        self._commit("add credential")
        path.unlink()
        self._commit("remove credential")
        for arguments in (["--all-history"],
                          ["--range", self.clean_base + "..HEAD"]):
            result = self._scan(arguments=arguments)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(secret, result.stdout + result.stderr)
            self.assertIn("removed.txt", result.stderr)

    def test_invalid_range_fails_closed(self):
        result = self._scan(arguments=["--range", "missing-ref..HEAD"])
        self.assertEqual(result.returncode, 2)

    def test_malformed_config_is_a_tool_error(self):
        (self.repo / ".gitleaks.toml").write_text("not = [valid", encoding="utf-8")
        result = self._scan()
        self.assertEqual(result.returncode, 2)

    def test_scanner_error_fails_closed_and_withholds_output(self):
        result = self._scan(fake=True, FAKE_SCANNER_ERROR="1")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("sensitive scanner diagnostic", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
