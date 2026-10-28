"""T03-01: complete app.yaml v1 semantic validation regression suite."""
import copy
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

from tools.validate_app_manifest import ManifestError, validate

ROOT = Path(__file__).resolve().parents[2]
NAMES = ("portainer", "sub2api")


class ManifestValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in NAMES:
            shutil.copytree(ROOT / name / "deploy", self.root / name / "deploy")
        shutil.copytree(ROOT / "schema", self.root / "schema")
        (self.root / "lib").mkdir()
        shutil.copy(ROOT / "lib/image-sources.sh", self.root / "lib/image-sources.sh")
        shutil.copy(ROOT / ".env.example", self.root / ".env.example")
        shutil.copy(ROOT / ".secrets.example", self.root / ".secrets.example")

    def fixture(self, name):
        path = self.root / "schema/examples" / f"{name}.app.yaml"
        return path, yaml.safe_load(path.read_text(encoding="utf-8"))

    def mutate(self, name, changer):
        path, data = self.fixture(name)
        changer(data)
        path.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True),
                        encoding="utf-8")
        return path

    def fails(self, name, changer, contains):
        path = self.mutate(name, changer)
        with self.assertRaises(ManifestError) as caught:
            validate(path, self.root)
        self.assertIn(contains, str(caught.exception))

    def test_positive_actual_portainer_and_sub2api(self):
        for name in NAMES:
            with self.subTest(name=name):
                path, _ = self.fixture(name)
                result = validate(path, self.root)
                self.assertEqual(result["id"], name)
                self.assertEqual(result["primary_port_id"], "web")
                self.assertGreater(result["package_file_count"], 2)
        self.assertEqual(validate(self.fixture("sub2api")[0], self.root)["required_services"],
                         ["sub2api", "postgres", "redis"])

    def test_unknown_fields_and_required_schema(self):
        self.fails("portainer", lambda d: d.update({"new_permission": "exec"}), "Schema")
        self.fails("portainer", lambda d: d.pop("actions"), "Schema")

    def test_duplicate_yaml_keys_rejected(self):
        path, _ = self.fixture("portainer")
        path.write_text(path.read_text() + "\nid: evil\n", encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "Duplicate"):
            validate(path, self.root)

    def test_schema_valid_but_unknown_compose_project(self):
        self.fails("portainer", lambda d: d["runtime"].update({"compose_project": "hijack"}),
                   "Compose project")

    def test_missing_package_script(self):
        self.fails("sub2api", lambda d: d["package"]["files"].pop(2), "Action script")

    def test_missing_shared_dependency(self):
        self.fails("portainer",
                   lambda d: d["package"]["files"].pop(),
                   "Shared image-sources")

    def test_sourced_local_shell_dependency_must_be_packaged(self):
        self.fails("sub2api",
                   lambda d: d["package"]["files"].pop(3),
                   "Sourced install dependency")

    def test_compatibility_requires_docker_and_compose_v2(self):
        self.fails("portainer",
                   lambda d: d["compatibility"].pop("requires_compose_v2"),
                   "Docker Engine and Compose v2")

    def test_invalid_named_volume_not_silently_claimed(self):
        self.fails("sub2api",
                   lambda d: d["data"].update({"named_volumes": ["some-volume"]}),
                   "owned named volume")

    def test_symlink_package_source_rejected(self):
        shared = self.root / "lib/image-sources.sh"
        shared.unlink()
        shared.symlink_to(ROOT / "lib/image-sources.sh")
        path, _ = self.fixture("sub2api")
        with self.assertRaisesRegex(ManifestError, "symlink"):
            validate(path, self.root)

    def test_source_and_destination_path_traversal(self):
        self.fails("sub2api",
                   lambda d: d["package"]["files"][0].update({"destination": "../escape"}),
                   "Schema")
        self.fails("portainer",
                   lambda d: d["package"]["files"][0].update({"destination": "portainer/deploy/.env"}),
                   "hidden file")

    def test_casefold_duplicate_destination_or_source(self):
        def duplicate(d):
            d["package"]["files"].append(copy.deepcopy(d["package"]["files"][0]))
        self.fails("sub2api", duplicate, "Duplicate package")

    def test_protected_package_destination(self):
        self.fails("sub2api",
                   lambda d: d["package"]["files"][0].update({
                       "destination": "sub2api/data/docker-compose.yaml"}),
                   "protected data")

    def test_compose_port_variable_or_target_mismatch(self):
        self.fails("portainer",
                   lambda d: d["ports"][0].update({"container_port": 9001}),
                   "Compose port mapping")
        self.fails("sub2api",
                   lambda d: d["ports"][0].update({"host_port_key": "SUB2API_ADMIN_PASSWORD"}),
                   "Port references")

    def test_compose_service_verification_and_health(self):
        self.fails("portainer",
                   lambda d: d["verification"].update({"required_services": ["missing"]}),
                   "missing Compose services")
        self.fails("portainer",
                   lambda d: d["verification"].update({"state": "healthy"}),
                   "healthcheck")

    def test_secret_protection_and_generated_by_script(self):
        self.fails("sub2api",
                   lambda d: next(f for f in d["config"] if f["type"] == "secret")
                   .update({"default": "real-password"}),
                   "Schema")
        self.fails("portainer",
                   lambda d: d["config"][0].update({"generated_by_script": True}),
                   "Auto-generation")

    def test_rejects_install_or_uninstall_command_injection(self):
        self.fails("portainer",
                   lambda d: d["actions"]["install"].update({"argv": [";rm -rf /"]}),
                   "Unapproved")
        self.fails("sub2api",
                   lambda d: d["actions"]["install"].update({"strategy": "compose_down", "path": None}),
                   "Schema")

    def test_data_mount_and_default_retain(self):
        self.fails("portainer", lambda d: d["data"].update({"paths": ["portainer/data/other"]}),
                   "Data path absent")
        self.fails("sub2api", lambda d: d["data"].update({"default_retain": False}),
                   "Schema")

    def test_rejects_secret_missing_from_global_template(self):
        self.fails("portainer",
                   lambda d: d["config"][1].update({"key": "NOT_IN_SECRETS"}),
                   "shared example template")

    def test_manifest_location_must_match_application_id(self):
        path, _ = self.fixture("portainer")
        other = self.root / "portainer/app.yaml"
        shutil.copy(path, other)
        self.assertEqual(validate(other, self.root)["id"], "portainer")
        wrong = self.root / "sub2api/app.yaml"
        shutil.copy(path, wrong)
        with self.assertRaisesRegex(ManifestError, "Production manifest"):
            validate(wrong, self.root)


if __name__ == "__main__":
    unittest.main()
