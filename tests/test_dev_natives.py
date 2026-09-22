"""dev-natives.py never lets a stale or altered native binary pass as current.

Runs the real stage() against a scratch repository with a real submodule and a
tiny recipe (a shell command that concatenates two inputs), and against a real
cache entry published by build.py. Only the repository root and recipe table
are pointed at the scratch tree.

    python3 -m unittest tests.test_dev_natives
"""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "scripts/container-build"
sys.path.insert(0, str(TOOLS))
import build  # noqa: E402

spec = importlib.util.spec_from_file_location("dev_natives", TOOLS / "dev-natives.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)

RECIPE = {
    "inputs": ["native_src", "sub"],
    "submodules": ["sub"],
    "command": "if grep -q FAIL native_src/a.txt; then exit 1; fi; "
               "mkdir -p out && cat native_src/a.txt sub/b.txt > out/lib.so && echo x >> builds",
    "outputs": ["out/lib.so"],
}


def git(where, *args):
    subprocess.run(["git", "-C", str(where), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "protocol.file.allow=always", *args], check=True, capture_output=True)


class DevNativesTest(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="devnat-"))
        upstream = self.scratch / "upstream"
        upstream.mkdir()
        git(upstream, "init", "-q")
        (upstream / "b.txt").write_text("B\n")
        git(upstream, "add", "b.txt")
        git(upstream, "commit", "-qm", "sub")
        self.repo = self.scratch / "repo"
        (self.repo / "native_src").mkdir(parents=True)
        git(self.repo, "init", "-q")
        (self.repo / "native_src/a.txt").write_text("A\n")
        (self.repo / ".gitignore").write_text("out/\nbuilds\n")
        git(self.repo, "submodule", "add", "-q", str(upstream), "sub")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "init")
        self.saved = (build.REPO, dev.REPO, build.RECIPES)
        build.REPO = dev.REPO = self.repo
        build.RECIPES = {"fake": RECIPE}

    def tearDown(self):
        build.REPO, dev.REPO, build.RECIPES = self.saved
        subprocess.run(["chmod", "-R", "u+w", str(self.scratch)], check=True)
        shutil.rmtree(self.scratch)

    def output(self):
        return (self.repo / "out/lib.so").read_text()

    def builds(self):
        return len((self.repo / "builds").read_text().splitlines())

    def test_local_builds_track_every_edit_tamper_and_failure(self):
        self.assertEqual(dev.stage("fake", None), "local build (no cache entry)")
        self.assertEqual((self.output(), self.builds()), ("A\nB\n", 1))
        self.assertEqual(dev.stage("fake", None), "up to date (local)")
        self.assertEqual(self.builds(), 1)

        # Two different edits in a submodule that stays dirty: each rebuilds.
        for text in ("B2\n", "B3\n"):
            (self.repo / "sub/b.txt").write_text(text)
            self.assertEqual(dev.stage("fake", None), "local build (inputs edited)")
            self.assertEqual(self.output(), "A\n" + text)
        self.assertEqual(self.builds(), 3)

        # Same sources, altered output: rebuilt, not vouched for.
        (self.repo / "out/lib.so").write_text("tampered")
        self.assertNotEqual(dev.stage("fake", None), "up to date (local)")
        self.assertEqual((self.output(), self.builds()), ("A\nB3\n", 4))

        # A failed build leaves no stamp and no output; reverting the edit
        # that broke it rebuilds instead of reusing anything older.
        (self.repo / "native_src/a.txt").write_text("FAIL\n")
        with self.assertRaisesRegex(dev.Refused, "local build failed"):
            dev.stage("fake", None)
        self.assertFalse((self.repo / "out/lib.so").exists())
        (self.repo / "native_src/a.txt").write_text("A\n")
        self.assertEqual(dev.stage("fake", None), "local build (inputs edited)")
        self.assertEqual((self.output(), self.builds()), ("A\nB3\n", 5))

    def test_cache_entries_are_verified_on_every_use_and_tied_to_the_builder(self):
        cache = self.scratch / "cache"
        head = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        ids = build.input_ids(head, RECIPE)
        key = build.cache_key("fake", RECIPE, ids, "sha256:img")
        dest = cache / "builds/fake" / key
        dest.parent.mkdir(parents=True)
        work = Path(tempfile.mkdtemp(dir=dest.parent))
        (work / "files/out").mkdir(parents=True)
        (work / "files/out/lib.so").write_text("CACHED")
        (work / "toolchain.txt").write_text("test\n")
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        build.publish("fake", RECIPE, head, key, ids, ("t", "sha256:img"), started, work, dest)
        manifest = {"builder_image": {"tag": build.builder_tag(), "id": "sha256:img"}, "cache": str(cache)}

        self.assertEqual(dev.stage("fake", manifest), f"cache {key}")
        self.assertTrue((self.repo / "out/lib.so").is_symlink())
        self.assertEqual(self.output(), "CACHED")
        self.assertEqual(dev.stage("fake", manifest), "up to date (cache)")

        # Another builder image means another key: no entry, so a local build.
        other = {**manifest, "builder_image": {**manifest["builder_image"], "id": "sha256:other"}}
        self.assertEqual(dev.stage("fake", other), "local build (no cache entry)")
        self.assertEqual(self.output(), "A\nB\n")

        # Back on the entry, then alter it: refused, never used or rebuilt over.
        self.assertEqual(dev.stage("fake", manifest), f"cache {key}")
        cached = dest / "files/out/lib.so"
        cached.chmod(0o644)
        cached.write_text("ALTERED")
        with self.assertRaisesRegex(dev.Refused, "does not verify"):
            dev.stage("fake", manifest)

    def test_an_image_from_another_builder_dockerfile_is_refused(self):
        path = self.scratch / "natives.json"
        path.write_text(json.dumps({"builder_image": {"tag": "minerva-container-build:000000000000",
                                                      "id": "sha256:img"}, "cache": None}))
        os.environ["MINERVA_NATIVES_MANIFEST"] = str(path)
        try:
            with self.assertRaisesRegex(dev.Refused, "rebuild the agent image"):
                dev.trusted_manifest()
        finally:
            del os.environ["MINERVA_NATIVES_MANIFEST"]


if __name__ == "__main__":
    unittest.main()
