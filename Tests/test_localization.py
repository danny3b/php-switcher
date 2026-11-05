"""Check complete locale coverage and safe interpolation in shipped catalogs."""
from collections import Counter
import ast
import json
from pathlib import Path
import plistlib
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def catalog(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


class LocalizationTests(unittest.TestCase):
    def test_all_shipped_locales_have_complete_safe_translations(self):
        english = catalog(ROOT / "Resources/en.lproj/Localizable.strings")
        metadata = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.assertEqual(set(metadata["CFBundleLocalizations"]), {"pl", "en", "de", "fr", "it"})
        for language in ["en", "de", "fr", "it"]:
            with self.subTest(language=language):
                translations = catalog(ROOT / f"Resources/{language}.lproj/Localizable.strings")
                self.assertEqual(translations.keys(), english.keys())
                for key, value in translations.items():
                    self.assertTrue(value.strip(), key)
                    self.assertEqual(Counter(re.findall(r"\{\d+\}", key)), Counter(re.findall(r"\{\d+\}", value)), key)
                    self.assertEqual(re.match(r"^\s*", english[key]).group(), re.match(r"^\s*", value).group(), key)
                    self.assertEqual(re.search(r"\s*$", english[key]).group(), re.search(r"\s*$", value).group(), key)

    def test_all_literal_translation_calls_have_catalog_entries(self):
        keys = catalog(ROOT / "Resources/en.lproj/Localizable.strings")
        for source in (ROOT / "Sources").glob("*.swift"):
            for value in re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', source.read_text()):
                # JSON and Swift share the escapes used by these source strings.
                key = json.loads('"' + value + '"')
                self.assertIn(key, keys, f"{source.name}: {key}")

    def test_database_helper_messages_have_catalog_entries(self):
        keys = catalog(ROOT / "Resources/en.lproj/Localizable.strings")
        tree = ast.parse((ROOT / "Resources/import_database.py").read_text())
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not node.args:
                continue
            name = node.func.id if isinstance(node.func, ast.Name) else getattr(node.func, "attr", "")
            if name in {"DatabaseError", "update"} and isinstance(node.args[0], ast.Constant):
                self.assertIn(node.args[0].value, keys)


if __name__ == "__main__":
    unittest.main()
