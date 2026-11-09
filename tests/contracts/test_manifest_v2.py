"""通用配置定义、迁移和运行时凭据保护，不依赖应用名称分支。"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml
from tools.validate_app_manifest import ManifestError, resolve_config, validate, validate_field_presentation

ROOT = Path(__file__).resolve().parents[2]


class AppConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / "schema", self.root / "schema")
        shutil.copytree(ROOT / "sub2api", self.root / "demo-service")
        shutil.copytree(ROOT / "lib", self.root / "lib")
        for path in (self.root / "demo-service").rglob("*"):
            if path.is_file() and path.suffix in (".yaml", ".sh"):
                path.write_text(path.read_text().replace("sub2api", "demo-service"))
        self.manifest = self.root / "demo-service/app.yaml"

    def mutate_field(self, change):
        path = self.root / "demo-service/config.yaml"
        data = yaml.safe_load(path.read_text())
        change(data["fields"][0])
        path.write_text(yaml.safe_dump(data, allow_unicode=True))

    def test_easytier_manifest_uses_generic_role_selector_and_conditions(self):
        result = validate(ROOT / "easytier/app.yaml", ROOT)
        self.assertEqual(result["id"], "easytier")

    def test_select_and_conditional_field_metadata_is_generic(self):
        fields = [
            {
                "key": "ROLE", "type": "string", "default": "cloud",
                "options": [
                    {"label": "Cloud", "value": "cloud"},
                    {"label": "Intranet", "value": "intranet"},
                ],
                "custom_input": True,
            },
            {
                "key": "CLOUD_URL", "type": "string",
                "visible_when": {"field": "ROLE", "equals": "cloud"},
            },
            {
                "key": "INTRANET_URL", "type": "string",
                "visible_when": {"field": "ROLE", "equals": "intranet"},
            },
        ]
        validate_field_presentation(fields)

        invalid = [
            ([{**fields[0], "default": "unknown"}, *fields[1:]], "Select default"),
            ([fields[0], {**fields[1], "visible_when": {"field": "MISSING", "equals": "cloud"}}, fields[2]], "unknown"),
            ([fields[0], {**fields[1], "visible_when": {"field": "ROLE", "equals": "missing"}}, fields[2]], "not declared"),
            ([fields[0], {**fields[1], "visible_when": {"field": "ROLE", "equals": "cloud"}}, {
                **fields[2], "visible_when": {"field": "CLOUD_URL", "equals": "intranet"}
            }], "cannot itself be conditional"),
        ]
        for candidate, message in invalid:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ManifestError, message):
                    validate_field_presentation(candidate)

    def test_unknown_application_uses_same_contract(self):
        self.assertEqual(validate(self.manifest, self.root)["id"], "demo-service")

    def test_stale_defaults_and_impossible_fields_are_rejected(self):
        self.mutate_field(lambda f: f.update(default=8123))
        with self.assertRaisesRegex(ManifestError, "默认值模板"):
            validate(self.manifest, self.root)
        self.mutate_field(lambda f: f.update(type="string", default="", required=True, custom_input=False))
        with self.assertRaisesRegex(ManifestError, "必填"):
            validate(self.manifest, self.root)

    def test_duplicate_fields_and_secret_defaults_are_rejected(self):
        path = self.root / "demo-service/secrets.yaml"
        data = yaml.safe_load(path.read_text())
        data["fields"][0]["default"] = "forbidden-example"
        path.write_text(yaml.safe_dump(data))
        with self.assertRaisesRegex(ManifestError, "密钥默认值"):
            validate(self.manifest, self.root)

    def test_missing_icon_is_rejected(self):
        (self.root / "demo-service/assets/icon.svg").unlink()
        with self.assertRaises(ManifestError):
            validate(self.manifest, self.root)

    def load_runtime(self):
        result = subprocess.run(["bash", "-c", 'source "$1"; deploy_load_app_config "$2" demo-service',
                                 "test", str(ROOT / "lib/app-config.sh"), str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        return self.root / "demo-service/config"

    def test_migration_preserves_existing_values_and_never_executes_credentials(self):
        legacy = self.root / "deploy"
        legacy.mkdir()
        (legacy / ".env").write_text('SUB2API_HTTP_PORT="8123"\nUNRELATED="keep"\n')
        secret = ' 空 格"\'中文$() `echo SHOULD_NOT_RUN` #= '
        original = 'SUB2API_POSTGRES_PASSWORD="' + secret + '"\n'
        (legacy / ".secrets").write_text(original)
        runtime = self.load_runtime()
        first = (runtime / ".secrets").read_bytes()
        self.assertIn(original, first.decode())
        self.assertNotIn("UNRELATED", (runtime / ".env").read_text())
        (legacy / ".env").write_text('SUB2API_HTTP_PORT="9999"\n')
        (legacy / ".secrets").write_text('SUB2API_POSTGRES_PASSWORD="replacement"\n')
        self.load_runtime()
        self.assertEqual((runtime / ".secrets").read_bytes(), first)
        self.assertIn('SUB2API_HTTP_PORT="8123"', (runtime / ".env").read_text())
        self.assertEqual((runtime / ".secrets").stat().st_mode & 0o777, 0o600)

    def test_duplicate_legacy_keys_fail_without_overwriting_current_file(self):
        legacy = self.root / "deploy"; legacy.mkdir()
        (legacy / ".env").write_text('SUB2API_HTTP_PORT=8000\nSUB2API_HTTP_PORT=9000\n')
        result = subprocess.run(["bash", "-c", 'source "$1"; deploy_load_app_config "$2" demo-service',
                                 "test", str(ROOT / "lib/app-config.sh"), str(self.root)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"8000", result.stderr)

    def test_sync_seeds_native_config_and_preserves_runtime_files(self):
        import re
        source = self.root / "source"
        installed = self.root / "installed"
        for directory in (source / "demo-service/config", source / "demo-service/deploy", installed / "demo-service/config"):
            directory.mkdir(parents=True)
        (source / "demo-service/config/native.json").write_text('new template')
        (source / "demo-service/config/missing.json").write_text('initial template')
        (source / "demo-service/config/.env").write_text('MUST_NOT_COPY=1')
        (source / "demo-service/config/.secrets").write_text('MUST_NOT_COPY=1')
        (installed / "demo-service/config/native.json").write_text('user configuration')
        (installed / "demo-service/config/.env").write_text('KEEP=1')
        (installed / "demo-service/config/.secrets").write_text('KEEP=2')
        function = re.search(r'^sync_task\(\) \{\n.*?^\}', (ROOT / 'deploy.sh').read_text(), re.M | re.S).group()
        code = 'run_root() { "$@"; }; sync_shared_libraries() { :; };\n' + function + '\nROOT_DIR="$1"; SOFTWARE_ROOT="$2"; sync_task demo-service'
        result = subprocess.run(['bash', '-c', code, 'test', str(source), str(installed)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = installed / 'demo-service/config'
        self.assertEqual((directory / 'native.json').read_text(), 'user configuration')
        self.assertEqual((directory / 'missing.json').read_text(), 'initial template')
        self.assertEqual((directory / '.env').read_text(), 'KEEP=1')
        self.assertEqual((directory / '.secrets').read_text(), 'KEEP=2')
