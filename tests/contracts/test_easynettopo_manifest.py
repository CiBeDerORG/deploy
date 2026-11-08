"""EasyNetTopo 自身应用列入目录，同时保留原生部署的生命周期契约。"""
import unittest
from pathlib import Path
import yaml
from tools.validate_app_manifest import validate

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "easynettopo" / "app.yaml"


class EasyNetTopoManifestTests(unittest.TestCase):
    def test_enabled_manifest_is_valid(self):
        result = validate(MANIFEST, ROOT)
        self.assertEqual(result["id"], "easynettopo")
        self.assertEqual(result["required_services"], ["easynettopo"])
        self.assertEqual(result["primary_port_id"], "web")
        manifest = yaml.safe_load(MANIFEST.read_text(encoding="utf-8"))
        self.assertIs(manifest["enabled"], True)
        self.assertEqual(manifest["actions"]["update"]["path"], "deploy/update.sh")
        sources = {f["destination"] for f in manifest["package"]["files"]}
        for name in ("easynettopo/deploy/config.sh", "deploy/lib/versions.env",
                     "deploy/lib/versions.sh", "deploy/lib/image-sources.sh"):
            self.assertIn(name, sources)
        self.assertTrue(manifest["data"]["default_retain"])


if __name__ == "__main__":
    unittest.main()
