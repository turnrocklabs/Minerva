"""scripts/zig-prefetch.py reads only what it understands and trusts only the
manifest's hash.

    python3 -m unittest tests.test_zig_prefetch
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("zig_prefetch", ROOT / "scripts/zig-prefetch.py")
zp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zp)


class ZigPrefetchTest(unittest.TestCase):
    def test_the_shim_manifest_reads_as_its_one_pinned_dependency(self):
        deps = zp.dependencies((ROOT / "src/gdextension/terminal/ghostty-shim/build.zig.zon").read_text())
        self.assertEqual(list(deps), ["uucode"])
        self.assertTrue(deps["uucode"]["url"].startswith("https://"))
        self.assertTrue(deps["uucode"]["hash"].startswith("uucode-"))

    def test_shapes_it_does_not_understand_are_refused(self):
        for zon in ('.{ .dependencies = .{ .a = .{ .url = "u", .hash = "h" }, // trailing\n } }',
                    '.{ .dependencies = .{ .a = .{ .url = "u" } } }',
                    '.{ .dependencies = .{ .a = .{ .url = "u", .hash = "h", .extra = "x" } } }',
                    '.{ .dependencies = .{ .a = b } }'):
            with self.subTest(zon=zon), self.assertRaises(zp.Refused):
                zp.dependencies(zon)

    @unittest.skipUnless(shutil.which("zig") and shutil.which("curl"), "zig and curl needed")
    def test_an_archive_that_does_not_match_its_pinned_hash_is_refused(self):
        tmp = Path(tempfile.mkdtemp(prefix="zigpre-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "pkg").mkdir()
        (tmp / "pkg/build.zig.zon").write_text('.{ .name = .pkg, .version = "0.0.0", .paths = .{""} }\n')
        with tarfile.open(tmp / "pkg.tar.gz", "w:gz") as tar:
            tar.add(tmp / "pkg", arcname="pkg")
        manifest = tmp / "build.zig.zon"
        manifest.write_text('.{ .dependencies = .{ .pkg = .{ .url = "file://%s", .hash = "pkg-0.0.0-wrong" } } }'
                            % (tmp / "pkg.tar.gz"))
        os.environ["ZIG_GLOBAL_CACHE_DIR"] = str(tmp / "cache")
        self.addCleanup(os.environ.pop, "ZIG_GLOBAL_CACHE_DIR")
        with self.assertRaisesRegex(zp.Refused, "pins pkg-0.0.0-wrong"):
            zp.prefetch(manifest)


if __name__ == "__main__":
    unittest.main()
