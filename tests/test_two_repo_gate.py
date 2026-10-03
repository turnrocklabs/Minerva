"""Runner contract with real git and bash; no Docker or applications launched."""
import importlib.util
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/agent-container" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


jobs = load("gate_jobs", "jobs.py")
gate = load("two_repo_gate", "two-repo-gate.py")


class TwoRepoGateTest(unittest.TestCase):
    def test_sibling_checkout_is_pinned_and_setup_failure_is_visible(self):
        with tempfile.TemporaryDirectory(prefix="two-repo-gate-") as scratch:
            root = Path(scratch)
            source = root / "source"
            plugin = root / "sources/minerva-plugins"
            pins = []
            for repo in (source, plugin):
                repo.mkdir(parents=True)
                subprocess.run(["git", "init", "-q", str(repo)], check=True)
                (repo / "value").write_text("pinned")
                subprocess.run(["git", "-C", str(repo), "add", "value"], check=True)
                subprocess.run(["git", "-C", str(repo), "-c", "user.name=test", "-c",
                                "user.email=test@example.org", "commit", "-qm", "fixture"], check=True)
                pins.append(subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"]).decode().strip())
                (repo / "value").write_text("dirty content must not reach the job")
            for folder in ("in", "out", "work"):
                (root / folder).mkdir()
            script = jobs.IN_JOB
            # Relocate only container mount paths; the real setup shell is run.
            for old, new in (("/tmp/job", str(root / "work")), ("/sources", str(root / "sources")),
                             ("/src", str(source)), ("/job", str(root / "in")), ("/out", str(root / "out"))):
                script = script.replace(old, new)
            (root / "in/run.sh").write_text(script)
            (root / "in/siblings.tsv").write_text(f"minerva-plugins\t{pins[1]}\n")
            (root / "in/artifacts.txt").write_text("")
            (root / "in/command.sh").write_text('test "$(cat value)" = pinned && test "$(cat ../minerva-plugins/value)" = pinned\n')
            env = {**os.environ, "MINERVA_JOB_ID": "fixture", "MINERVA_JOB_REV": pins[0],
                   "MINERVA_JOB_FOLDER": str(source), "MINERVA_JOB_PRIMARY": "Minerva", "MINERVA_JOB_SECONDS": "60"}
            done = subprocess.run(["bash", str(root / "in/run.sh")], env=env)
            self.assertEqual(done.returncode, 0)
            self.assertEqual(jobs.assembled_revisions(root / "out"), {"Minerva": pins[0], "minerva-plugins": pins[1]})
            self.assertTrue(jobs._source(root / "out", "source-status-minerva-plugins")["dirty"])
            # The changed-GD range includes plugin scripts even outside src/.
            (plugin / "cad/ui").mkdir(parents=True)
            changed = plugin / "cad/ui/broken.gd"
            changed.write_text("extends ???\n")
            subprocess.run(["git", "-C", str(plugin), "add", "cad/ui/broken.gd"], check=True)
            subprocess.run(["git", "-C", str(plugin), "-c", "user.name=test", "-c",
                            "user.email=test@example.org", "commit", "-qm", "plugin parse fixture"], check=True)
            self.assertEqual(gate.changed_scripts(plugin, pins[1]), [changed])
            # Missing immutable pin is a setup failure, never a healthy command.
            (root / "in/siblings.tsv").write_text("minerva-plugins\t" + "0" * 40 + "\n")
            shutil.rmtree(root / "work")
            (root / "work").mkdir()
            done = subprocess.run(["bash", str(root / "in/run.sh")], env=env)
            self.assertNotEqual(done.returncode, 0)
            self.assertTrue((root / "out/ended").read_text().startswith("setup "))

    def test_changed_files_and_diagnostics_fail_closed(self):
        autoload = 'SCRIPT ERROR: Parse Error: Identifier "App" not declared in the current scope.'
        self.assertFalse(gate.check_errors("", 0))
        for rc, output in ((1, autoload), (124, autoload), (0, 'SCRIPT ERROR: Parse Error: broken syntax'),
                           (1, autoload + '\nSCRIPT ERROR: Parse Error: unexpected token'),
                           (0, 'ERROR: Cannot open file res://../../minerva-plugins/cad/ui/bad.gd'),
                           (2, ''), (1, 'SCRIPT ERROR: Compile Error: unknown class')):
            with self.subTest(rc=rc, output=output):
                self.assertTrue(gate.check_errors(output, rc))


if __name__ == "__main__":
    unittest.main()
