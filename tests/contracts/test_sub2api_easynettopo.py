"""EasyNetTopo M0: Sub2API 最小部署包与执行前置条件的静态回归。

本套测试不执行脚本，不启动 Docker，也不能作为脚本可信度证明。
"""
import unittest
from pathlib import Path

import yaml

from tools.validate_app_manifest import validate


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "sub2api" / "app.yaml"


class EasyNetTopoSub2APITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = yaml.safe_load(APP.read_text(encoding="utf-8"))
        cls.compose = yaml.safe_load((ROOT / "sub2api/deploy/docker-compose.yaml").read_text(
            encoding="utf-8"))

    def test_published_manifest_remains_valid(self):
        result = validate(APP, ROOT)
        self.assertEqual(result["id"], "sub2api")
        self.assertEqual(result["required_services"], ["sub2api", "postgres", "redis"])
        self.assertEqual(result["primary_port_id"], "web")

    def test_minimal_bundle_lists_every_script_dependency_without_runtime_secrets(self):
        files = {x["destination"]: x for x in self.manifest["package"]["files"]}
        required = {
            "sub2api/deploy/docker-compose.yaml",
            "sub2api/deploy/install.sh",
            "sub2api/deploy/update.sh",
            "sub2api/deploy/lib.sh",
            "deploy/lib/image-sources.sh",
        }
        self.assertEqual(set(files), required)
        self.assertEqual(files["sub2api/deploy/install.sh"]["mode"], "0755")
        self.assertEqual(files["sub2api/deploy/update.sh"]["mode"], "0755")
        self.assertFalse(any(".env" in p or ".secrets" in p or "/data/" in p
                             for p in files))
        # app.yaml 随发布包的元数据单独携带，不要求把 manifest 自己放进 package.files。
        self.assertEqual(self.manifest["actions"]["install"]["path"], "deploy/install.sh")

    def test_agent_must_prepare_global_configuration_before_installer(self):
        script = (ROOT / "sub2api/deploy/install.sh").read_text(encoding="utf-8")
        shared = (ROOT / "sub2api/deploy/lib.sh").read_text(encoding="utf-8")
        self.assertIn('ENV_FILE="$SOFTWARE_ROOT/deploy/.env"', script)
        self.assertIn('SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"', script)
        self.assertIn("load_global_config", script)
        self.assertIn('source "$DEPLOY_DIR/lib.sh"', script)
        self.assertIn('source "$IMAGE_SOURCES_LIB"', script)
        self.assertIn('[ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ]', shared)
        self.assertIn("chmod 0600", shared)

    def test_generated_secrets_match_the_real_installer(self):
        script = (ROOT / "sub2api/deploy/install.sh").read_text(encoding="utf-8")
        fields = [x for x in self.manifest["config"] if x.get("generated_by_script")]
        self.assertEqual({x["key"] for x in fields}, {
            "SUB2API_POSTGRES_PASSWORD", "SUB2API_REDIS_PASSWORD",
            "SUB2API_JWT_SECRET", "SUB2API_TOTP_ENCRYPTION_KEY",
        })
        self.assertIn("ensure_hex_secret", script)
        for field in fields:
            self.assertIn(field["key"], script)
            self.assertEqual(field["default"], "")
        self.assertTrue(self.manifest["data"]["default_retain"])

    def test_all_three_services_have_health_checks_and_only_web_is_published(self):
        services = self.compose["services"]
        self.assertEqual(set(services), {"sub2api", "postgres", "redis"})
        self.assertEqual(set(self.manifest["verification"]["required_services"]), set(services))
        self.assertEqual(self.manifest["verification"]["state"], "healthy")
        for name, service in services.items():
            self.assertIn("healthcheck", service, name)
            self.assertNotIn("privileged", service, name)
            self.assertNotIn("build", service, name)
            self.assertNotEqual(service.get("network_mode"), "host", name)
        self.assertFalse(services["postgres"].get("ports"))
        self.assertFalse(services["redis"].get("ports"))
        self.assertEqual(len(services["sub2api"].get("ports", [])), 1)


if __name__ == "__main__":
    unittest.main()
