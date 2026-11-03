import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import threading
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("install_php", Path(__file__).parents[1] / "Resources/install_php.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_progress_preserves_localization_key_and_literal_arguments(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(installer.Path, "home", return_value=Path(tmp)):
            state = Path(tmp) / "state.json"
            job = installer.Installer("8.4.27", state)
            try:
                message = installer.Message("Brakuje narzędzia: {0}", "/path/100% {0}/tool")
                with mock.patch("sys.stdout", new_callable=io.StringIO):
                    job.progress(0.2, message)
                record = json.loads(state.read_text())
                self.assertEqual(record["message"], "Brakuje narzędzia: /path/100% {0}/tool")
                self.assertEqual(record["messageKey"], "Brakuje narzędzia: {0}")
                self.assertEqual(record["messageArguments"], ["/path/100% {0}/tool"])
                with mock.patch("sys.stdout", new_callable=io.StringIO):
                    job.progress(0.3, "Przygotowanie instalacji…")
                self.assertEqual(json.loads(state.read_text())["messageArguments"], [])
            finally:
                job.cleanup()

    def test_cancel_stops_child_and_reports_cancellation(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(installer.Path, "home", return_value=Path(tmp)):
            job = installer.Installer("8.4.27")
            timer = threading.Timer(0.25, job.cancel)
            timer.start()
            started = time.monotonic()
            try:
                with self.assertRaisesRegex(installer.InstallError, "Instalacja anulowana"):
                    job.run(["/bin/sleep", "20"])
                self.assertLess(time.monotonic() - started, 5)
                self.assertTrue(job.cancelled)
            finally:
                timer.cancel()
                job.cleanup()

    def test_version_validation(self):
        for version in ["8.3.36", "8.4.27", "8.5.12"]:
            self.assertEqual(installer.valid_version(version), version)
        for version in ["../8.5.12", "8.5.12; rm x", "8.6.0", "8.4", "8.3.36\n"]:
            with self.assertRaises(installer.InstallError):
                installer.valid_version(version)

    def test_configure_inverse_options_and_removed_extensions(self):
        raw = "--with-iconv=/Library/Developer/CommandLineTools/SDKs/MacOSX14.sdk/usr --with-pspell=/old --enable-mbregex --prefix=/old PKG_CONFIG_PATH=/libs"
        args, env = installer.configure_options(raw, Path("/new"), "/sdk", "--without-iconv --disable-mbregex")
        self.assertIn("--with-iconv=/sdk/usr", args)
        self.assertIn("--enable-mbregex", args)
        self.assertFalse(any("pspell" in item or item == "--prefix=/old" for item in args))
        self.assertEqual(env["PKG_CONFIG_PATH"], "/libs")
        self.assertIn("--prefix=/new", args)

    def test_tar_traversal_and_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, kind in [("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE), ("link", tarfile.SYMTYPE)]:
                archive = root / "bad.tar"
                with tarfile.open(archive, "w") as tar:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    entry.linkname = "../../escape"
                    tar.addfile(entry, io.BytesIO(b""))
                with self.assertRaises(installer.InstallError):
                    installer.safe_extract(archive, root / "out")

    def test_regular_archive_extracts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "good.tar"
            with tarfile.open(archive, "w") as tar:
                entry = tarfile.TarInfo("php/test.txt")
                entry.size = 2
                tar.addfile(entry, io.BytesIO(b"ok"))
            installer.safe_extract(archive, root / "out")
            self.assertEqual((root / "out/php/test.txt").read_text(), "ok")


if __name__ == "__main__":
    unittest.main()
