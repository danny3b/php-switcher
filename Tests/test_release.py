"""Verify that manual installers cannot publish a different application."""
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

MODULE_PATH = Path(__file__).resolve().parents[1] / "Scripts/publish_release.py"
SPEC = importlib.util.spec_from_file_location("publish_release", MODULE_PATH)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "PHP Switcher.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/program").write_bytes(b"original app")
        (self.app / "Current").symlink_to("Contents")
        self.archive = self.root / "app.zip"
        with zipfile.ZipFile(self.archive, "w") as package:
            package.writestr("PHP Switcher.app/Contents/program", b"original app")
            link = zipfile.ZipInfo("PHP Switcher.app/Current")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            package.writestr(link, "Contents")
            package.writestr("__MACOSX/._PHP Switcher.app", b"metadata")

    def test_matching_app_and_framework_links_are_accepted(self):
        release.verify_bundle_matches_archive(self.app, self.archive)

    def test_changed_app_is_rejected(self):
        (self.app / "Contents/program").write_bytes(b"different app")
        with self.assertRaisesRegex(RuntimeError, "file differs"):
            release.verify_bundle_matches_archive(self.app, self.archive)

    def test_changed_symbolic_link_is_rejected(self):
        (self.app / "Current").unlink()
        (self.app / "Current").symlink_to("/Applications")
        with self.assertRaisesRegex(RuntimeError, "symbolic link differs"):
            release.verify_bundle_matches_archive(self.app, self.archive)

    def test_extra_app_content_is_rejected(self):
        (self.app / "Contents/extra").write_bytes(b"unexpected file")
        with self.assertRaisesRegex(RuntimeError, "file lists differ"):
            release.verify_bundle_matches_archive(self.app, self.archive)

    def test_missing_app_content_is_rejected(self):
        (self.app / "Contents/program").unlink()
        with self.assertRaisesRegex(RuntimeError, "file differs"):
            release.verify_bundle_matches_archive(self.app, self.archive)


if __name__ == "__main__":
    unittest.main()
