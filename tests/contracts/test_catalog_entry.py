"""商店展示、macOS 原生安装条目与既有部署清单的兼容性测试。"""
import io
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import yaml

from tools.validate_app_manifest import ManifestError, main, published_manifests, validate

ROOT = Path(__file__).resolve().parents[2]


class CatalogEntryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "schema").mkdir()
        shutil.copy(ROOT / "schema/app-catalog-entry.schema.json", self.root / "schema")
        self.native_entry = yaml.safe_load((ROOT / "maestro/app.yaml").read_text())
        self.entry = self.native_entry.copy()
        del self.entry["native_install"]
        self.entry["catalog_only"] = True
        self.path = self.root / "工具/mac/app.yml"
        self.path.parent.mkdir(parents=True)

    def write(self, data):
        self.path.write_text(yaml.safe_dump(data, allow_unicode=True), encoding="utf-8")

    def test_nested_entry_and_switch(self):
        del self.entry["enabled"]
        self.write(self.entry)
        self.assertEqual(validate(self.path, self.root), {
            "id": "maestro", "enabled": True, "catalog_only": True,
        })
        self.write({**self.entry, "enabled": False})
        self.assertFalse(validate(self.path, self.root)["enabled"])

    def test_catalog_mode_requires_valid_metadata_and_has_no_execution_fields(self):
        for changes in ({"enabled": "yes"}, {"catalog_only": False}, {"id": "../app"},
                        {"actions": {}}, {"schema_version": 2}, {"runtime": {}}):
            with self.subTest(changes=changes):
                self.write({**self.entry, **changes})
                with self.assertRaises(ManifestError):
                    validate(self.path, self.root)

    def test_native_install_mode_uses_known_platform_and_app(self):
        self.assertEqual(validate(ROOT / "maestro/app.yaml", ROOT), {
            "id": "maestro", "enabled": True, "native_install": "macos_homebrew",
        })
        self.write({**self.native_entry, "enabled": False})
        self.assertFalse(validate(self.path, self.root)["enabled"])
        for changes in ({"id": "another-tool"}, {"native_install": "brew install foo"},
                        {"catalog_only": True}, {"catalog_only": False},
                        {"runtime": {}}, {"actions": {}}, {"formula": "other/tap/maestro"}):
            with self.subTest(changes=changes):
                self.write({**self.native_entry, **changes})
                with self.assertRaises(ManifestError):
                    validate(self.path, self.root)

    def test_icon_relative_to_manifest(self):
        self.write({**self.entry, "icon": "assets/icon.svg"})
        assets = self.path.parent / "assets"
        assets.mkdir()
        icon = assets / "icon.svg"
        icon.write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
        self.assertTrue(validate(self.path, self.root)["catalog_only"])
        icon.write_text('<svg><script/></svg>')
        with self.assertRaisesRegex(ManifestError, "SVG"):
            validate(self.path, self.root)

    def test_discovery_uses_tracked_files_and_rejects_duplicate_ids(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write(self.entry)
        sibling = self.root / "app.yaml"
        sibling.write_bytes(self.path.read_bytes())
        subprocess.run(["git", "-C", str(self.root), "add", "工具/mac/app.yml"], check=True)
        self.assertEqual(published_manifests(self.root), [self.path])
        subprocess.run(["git", "-C", str(self.root), "add", "app.yaml"], check=True)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(main(["--all", "--root", str(self.root)]), 1)
        self.assertIn("应用 ID 重复", errors.getvalue())
