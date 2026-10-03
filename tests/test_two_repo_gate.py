"""Runner contract with real git and bash; no Docker or applications launched."""
import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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
                script = re.sub(re.escape(old) + r'(?=/|["\s;])', lambda _: new, script)
            self.assertIn(f"exec >>{root / 'out/job.log'} 2>&1", script)
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
            self.assertIn("== sibling minerva-plugins: " + "0" * 40 + " not found", (root / "out/job.log").read_text())
            self.assertTrue((root / "out/ended").read_text().startswith("setup "))

    @contextmanager
    def driver_fixture(self, preexisting=False):
        """Real subprocesses exercise the driver; the tiny Godot stand-in emits diagnostics."""
        with tempfile.TemporaryDirectory(prefix="gate-driver-") as scratch:
            root = Path(scratch)
            host, plugins = root / "Minerva", root / "minerva-plugins"
            pins = []
            for repo in (host, plugins):
                repo.mkdir()
                subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (host / "src").mkdir()
            (host / "src/contract.gd").write_text("extends RefCounted\n")
            for plugin in ("cad", "other"):
                (plugins / plugin).mkdir()
                (plugins / plugin / "consumer.gd").write_text('extends "res://contract.gd"\n')
            if preexisting:
                with (plugins / "cad/consumer.gd").open("a") as out:
                    out.write("# diagnostic SCRIPT ERROR: Parse Error: existing\n")
            (host / "src/project.godot").write_text('[autoload]\nFixtureGlobal="*res://contract.gd"\n')
            native = host / "scripts/container-build/dev-natives.py"
            native.parent.mkdir(parents=True)
            native.write_text("# Native staging is unrelated to these driver oracles.\n")
            for repo in (host, plugins):
                subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
                subprocess.run(["git", "-C", str(repo), "-c", "user.name=test", "-c",
                                "user.email=test@example.org", "commit", "-qm", "base"], check=True)
                pins.append(gate.git(repo, "rev-parse", "HEAD"))
            manifest = root / "natives.json"
            manifest.write_text("{}")
            fake = root / "godot"
            fake.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
if "--version" in sys.argv:
    print("fixture")
elif "--import" in sys.argv:
    counter = pathlib.Path("imports")
    n = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(n))
    if n == int(os.environ.get("FAIL_IMPORT", "0")):
        print(os.environ["IMPORT_DIAGNOSTIC"])
        sys.exit(int(os.environ.get("FAIL_IMPORT_RC", "0")))
elif "--check-only" in sys.argv:
    script = sys.argv[-1]
    path = pathlib.Path("src") / script.removeprefix("res://")
    for line in path.read_text().splitlines():
        if line.startswith("# diagnostic "):
            print(line.removeprefix("# diagnostic "))
    if "consumer.gd" in script and not pathlib.Path("src/contract.gd").exists():
        print("SCRIPT ERROR: Parse Error: missing host contract")
''')
            fake.chmod(0o755)
            args = argparse.Namespace(host_base=pins[0], plugins_base=pins[1],
                                      godot=str(fake), check_script=[], plugin=[])
            old_cwd = Path.cwd()
            try:
                os.chdir(host)
                with patch.object(gate, "JOB_ROOT", root), patch.dict(os.environ, {
                        "MINERVA_JOB_ID": "fixture", "MINERVA_NATIVES_MANIFEST": str(manifest)}):
                    yield host, plugins, args
            finally:
                os.chdir(old_cwd)

    def test_driver_fails_unchanged_plugin_after_host_deletion(self):
        with self.driver_fixture() as (host, plugins, args):
            (host / "src/contract.gd").unlink()
            subprocess.run(["git", "add", "-u"], check=True)
            subprocess.run(["git", "-c", "user.name=test", "-c", "user.email=test@example.org",
                            "commit", "-qm", "host-only deletion"], check=True)
            self.assertEqual(gate.changed_scripts(plugins, args.plugins_base), [])
            self.assertEqual(gate.run_gate(args), 1)
            receipt = json.loads((host / "gate-evidence/receipt.json").read_text())
            checks = [step for step in receipt["steps"] if step["name"].startswith("check-")]
            self.assertEqual([step["script"] for step in checks], ["minerva-plugins/cad/consumer.gd",
                                                                         "minerva-plugins/other/consumer.gd"])
            self.assertFalse(checks[0]["passed"])

    def test_driver_warms_first_import_and_rejects_second_import_diagnostics(self):
        for number in (1, 2):
            for diagnostic in ("SCRIPT ERROR: Parse Error: fixture", "ERROR: Cannot import fixture"):
                with self.subTest(number=number, diagnostic=diagnostic), self.driver_fixture() as (host, plugins, args):
                    self.assertEqual(gate.plugin_checks(host, plugins, args.host_base, args.plugins_base, []), ([], []))
                    with patch.dict(os.environ, {"FAIL_IMPORT": str(number), "IMPORT_DIAGNOSTIC": diagnostic}):
                        self.assertEqual(gate.run_gate(args), 0 if number == 1 else 1)
                    receipt = json.loads((host / "gate-evidence/receipt.json").read_text())
                    self.assertIn(diagnostic, receipt["steps"][1 + number]["diagnostics"])
                    if number == 2:
                        self.assertEqual(receipt["error"], "import-2 failed")
                        self.assertEqual(receipt["steps"][-1]["exit_code"], 0)
                        self.assertFalse(any(step["name"].startswith("check-") for step in receipt["steps"]))

    def test_first_import_nonzero_exit_fails(self):
        with self.driver_fixture() as (host, plugins, args), patch.dict(os.environ, {
                "FAIL_IMPORT": "1", "FAIL_IMPORT_RC": "1", "IMPORT_DIAGNOSTIC": "ERROR: warmup failed"}):
            self.assertEqual(gate.run_gate(args), 1)
            receipt = json.loads((host / "gate-evidence/receipt.json").read_text())
            self.assertEqual(receipt["error"], "import-1 failed")

    def test_changed_files_and_diagnostics_fail_closed(self):
        autoload = 'SCRIPT ERROR: Parse Error: Identifier "App" not declared in the current scope.'
        self.assertFalse(gate.check_errors("", 0))
        for rc, output in ((1, autoload), (124, autoload), (0, 'SCRIPT ERROR: Parse Error: broken syntax'),
                           (1, autoload + '\nSCRIPT ERROR: Parse Error: unexpected token'),
                           (0, '   ERROR: Cannot open file res://../../minerva-plugins/cad/ui/bad.gd'),
                           (2, ''), (1, 'SCRIPT ERROR: Compile Error: unknown class')):
            with self.subTest(rc=rc, output=output):
                self.assertTrue(gate.check_errors(output, rc))

    def test_context_and_baseline_comparison_fail_closed(self):
        with self.driver_fixture() as (host, plugins, args):
            names = gate.autoload_names(host)
            self.assertEqual(names, {"FixtureGlobal"})
        missing = "SCRIPT ERROR: Compile Error: Identifier not found: FixtureGlobal"
        cascade = 'SCRIPT ERROR: Compile Error: Failed to compile depended scripts.\nERROR: Failed to load script "res://consumer.gd" with error "Compilation failed".'
        self.assertTrue(gate.context_only(missing + "\n" + cascade, 1, names))
        for output in (cascade, missing.replace("FixtureGlobal", "Unknown"),
                       missing + "\nSCRIPT ERROR: Parse Error: unexpected token", missing + "\nERROR: Cannot open resource"):
            self.assertFalse(gate.context_only(output, 1, names))
        self.assertFalse(gate.context_only(missing, 124, names))
        before = 'SCRIPT ERROR: Parse Error: existing\n at: GDScript::reload (res://consumer.gd:3)'
        for after in (before + "\nSCRIPT ERROR: Parse Error: new", before + "\n" + before, before.replace(":3)", ":4)")):
            self.assertTrue(gate.error_records(after) - gate.error_records(before))
        self.assertFalse(gate.error_records(before) - gate.error_records(before))

    def test_driver_compares_exact_base_and_rejects_mixed_new_error(self):
        for mixed in (False, True):
            with self.subTest(mixed=mixed), self.driver_fixture(preexisting=True) as (host, plugins, args):
                with (plugins / "cad/consumer.gd").open("a") as out:
                    out.write("# diagnostic SCRIPT ERROR: Parse Error: introduced\n" if mixed else "# unrelated edit\n")
                subprocess.run(["git", "-C", str(plugins), "add", "."], check=True)
                subprocess.run(["git", "-C", str(plugins), "-c", "user.name=test", "-c",
                                "user.email=test@example.org", "commit", "-qm", "plugin head"], check=True)
                self.assertEqual(gate.run_gate(args), 1 if mixed else 0)
                receipt = json.loads((host / "gate-evidence/receipt.json").read_text())
                self.assertEqual(receipt["preexisting_failures"], [] if mixed else ["minerva-plugins/cad/consumer.gd"])
                self.assertTrue(any(step["name"].startswith("base-check-") for step in receipt["steps"]))

    def test_native_manifest_environment_is_reserved(self):
        class Host:
            Refused = ValueError
        with self.assertRaises(ValueError):
            jobs.env_from(Host(), ["MINERVA_NATIVES_MANIFEST=/untrusted"])


if __name__ == "__main__":
    unittest.main()
