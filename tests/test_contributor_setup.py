#!/usr/bin/env python3
"""Exercise source reuse and patch safety in disposable directories, with real files/git."""
import hashlib
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ContributorSetupTest(unittest.TestCase):
    def test_voice_runtime_fingerprint_tracks_only_producer_inputs(self):
        with tempfile.TemporaryDirectory(prefix="minerva-voice-inputs-") as directory:
            plugin = Path(directory)
            relative_inputs = [
                "scripts/build-runtime.sh",
                "scripts/requirements-runtime.lock",
                "scripts/runtime-bundle.lock",
                "scripts/voice_runtime_inputs.py",
                "worker/minerva_voice_worker/__init__.py",
                "worker/minerva_voice_worker/server.py",
            ]
            source_plugin = ROOT / "src/plugins/voice"
            for relative in relative_inputs:
                destination = plugin / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_plugin / relative, destination)
            namespace = runpy.run_path(str(plugin / "scripts/voice_runtime_inputs.py"),
                                       run_name="voice_runtime_inputs_test")
            digest = namespace["source_digest"]
            baseline = digest(plugin)

            unrelated = plugin / "worker/.venv/lib/python/site.py"
            unrelated.parent.mkdir(parents=True)
            unrelated.write_text("local environment", encoding="utf-8")
            self.assertEqual(digest(plugin), baseline,
                             "a developer venv is not copied into the runtime")

            for relative in ("worker/minerva_voice_worker/server.py",
                             "scripts/requirements-runtime.lock",
                             "scripts/runtime-bundle.lock",
                             "scripts/voice_runtime_inputs.py",
                             "scripts/build-runtime.sh"):
                path = plugin / relative
                original = path.read_bytes()
                path.write_bytes(original + b"\n# changed\n")
                self.assertNotEqual(digest(plugin), baseline, relative)
                path.write_bytes(original)
                self.assertEqual(digest(plugin), baseline, relative)

    def test_verified_jsoncons_reuse_and_local_edits(self):
        with tempfile.TemporaryDirectory(prefix="minerva-jsoncons-check-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            script = root / "scripts/build-json-schema-helper.py"
            shutil.copy2(ROOT / "scripts" / script.name, script)
            patch = Path("src/native/json_schema_helper/jsoncons-integral-multiple-of.patch")
            (root / patch).parent.mkdir(parents=True)
            shutil.copy2(ROOT / patch, root / patch)
            env = dict(os.environ, MINERVA_DEPENDENCY_CACHE=str(
                Path(os.environ.get("MINERVA_DEPENDENCY_CACHE", ROOT / ".dependency-cache")).resolve()))
            command = [sys.executable, str(script), "--platform", "linux", "--acquire-only"]
            first = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            header = root / "src/native/vendor/jsoncons/include/jsoncons/json.hpp"
            before = header.stat().st_mtime_ns
            second = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("already current", second.stdout)
            self.assertEqual(before, header.stat().st_mtime_ns)
            edited = header.read_bytes() + b"\n// contributor experiment\n"
            header.write_bytes(edited)
            rejected = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Preserve any local edits", rejected.stderr)
            self.assertEqual(edited, header.read_bytes())

    def test_wry_rerun_preserves_edits_and_conflicts(self):
        with tempfile.TemporaryDirectory(prefix="minerva-wry-check-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "patches").mkdir()
            script = root / "scripts/apply-wry-patches.py"
            shutil.copy2(ROOT / "scripts" / script.name, script)
            vendor = root / "vendor/godot_wry"
            vendor.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(vendor)], check=True)
            subprocess.run(["git", "-C", str(vendor), "config",
                            "user.email", "fixture@minerva.invalid"], check=True)
            subprocess.run(["git", "-C", str(vendor), "config",
                            "user.name", "Minerva fixture"], check=True)
            target = vendor / "source.txt"
            target.write_text("first: upstream\nsecond: upstream\n", encoding="utf-8")
            lock = vendor / "rust/Cargo.lock"
            lock.parent.mkdir(parents=True)
            dependency_root = vendor / "rust/.minerva-deps"
            dependency_root.mkdir()
            crate_source = root / "crate-source/wry-0.0.1"
            (crate_source / "src").mkdir(parents=True)
            (crate_source / "src/ipc.rs").write_text("upstream uri\n", encoding="utf-8")
            archive = dependency_root / "wry-0.0.1.crate"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(crate_source, arcname="wry-0.0.1")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            lock.write_text(
                '[[package]]\nname = "wry"\nversion = "0.0.1"\n'
                'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
                f'checksum = "{checksum}"\n', encoding="utf-8")
            subprocess.run(["git", "-C", str(vendor), "add",
                            "source.txt", "rust/Cargo.lock"], check=True)
            subprocess.run(["git", "-C", str(vendor), "commit", "-qm",
                            "fixture upstream"], check=True)
            target.write_text("first: patched\nsecond: upstream\n", encoding="utf-8")
            diff = subprocess.run(["git", "-C", str(vendor), "diff"],
                                  check=True, capture_output=True).stdout
            (root / "patches/godot_wry-first.patch").write_bytes(diff)
            (root / "patches/godot_wry-second.patch").write_text(
                "diff --git a/source.txt b/source.txt\n"
                "--- a/source.txt\n"
                "+++ b/source.txt\n"
                "@@ -1,2 +1,2 @@\n"
                " first: patched\n"
                "-second: upstream\n"
                "+second: patched\n", encoding="utf-8")
            target.write_text("first: upstream\nsecond: upstream\n", encoding="utf-8")
            (root / "patches/wry-0.0.1-file-ipc-request-uri.patch").write_text(
                "diff --git a/src/ipc.rs b/src/ipc.rs\n"
                "--- a/src/ipc.rs\n"
                "+++ b/src/ipc.rs\n"
                "@@ -1 +1 @@\n"
                "-upstream uri\n"
                "+patched uri\n", encoding="utf-8")
            local = vendor / "contributor.txt"
            local.write_text("keep my work\n", encoding="utf-8")
            command = [sys.executable, str(script)]
            for _ in range(2):
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(target.read_text(),
                                 "first: patched\nsecond: patched\n")
                self.assertEqual(local.read_text(), "keep my work\n")
                self.assertEqual((dependency_root / "wry-0.0.1/src/ipc.rs").read_text(),
                                 "patched uri\n")
            target.write_text("conflicting contributor edit\n", encoding="utf-8")
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("local WRY edits were preserved", rejected.stderr)
            self.assertEqual(target.read_text(), "conflicting contributor edit\n")
            self.assertEqual(local.read_text(), "keep my work\n")


if __name__ == "__main__":
    unittest.main()
