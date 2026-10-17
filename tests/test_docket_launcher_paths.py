"""Cross-platform private-profile containment contract for the Docket fixture."""
import runpy
import unittest
from pathlib import Path, PurePosixPath, PureWindowsPath

inside_root = runpy.run_path(str(Path(__file__).resolve().parents[1] /
                                  "src/test/fixtures/docket_launcher.py"))["profile_is_inside_root"]


class DocketLauncherPaths(unittest.TestCase):
    def test_windows_child_with_mixed_separators_and_case(self) -> None:
        self.assertTrue(inside_root(r"C:\Tests\Profiles/session", r"c:\tests\profiles", PureWindowsPath))
        self.assertTrue(inside_root("/tests/profiles/session", "/tests/profiles", PurePosixPath))

    def test_outside_sibling_equal_and_relative_are_rejected(self) -> None:
        for path_class, root, paths in [
            (PureWindowsPath, r"C:\Tests\Profiles", [r"C:\Other\session", r"C:\Tests\Profiles-old\session",
                                                       r"C:\Tests\Profiles", r"Profiles\session"]),
            (PurePosixPath, "/tests/profiles", ["/other/session", "/tests/profiles-old/session",
                                                "/tests/profiles", "profiles/session"]),
        ]:
            for profile in paths:
                with self.subTest(profile=profile):
                    self.assertFalse(inside_root(profile, root, path_class))
            self.assertFalse(inside_root(paths[0], "relative-root", path_class))


if __name__ == "__main__":
    unittest.main()
