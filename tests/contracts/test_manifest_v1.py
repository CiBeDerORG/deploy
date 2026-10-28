"""T00-05: offline JSON Schema + actual Deploy script/Compose fixture checks."""
import copy
import posixpath
import re
import unittest
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator, FormatChecker, ValidationError

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = yaml.safe_load((ROOT / "schema/app-manifest-v1.schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA, format_checker=FormatChecker())
EXAMPLES = ["portainer", "sub2api"]


def load(name):
    return yaml.safe_load((ROOT / f"schema/examples/{name}.app.yaml").read_text(encoding="utf-8"))


class DeployManifestTests(unittest.TestCase):
    def test_schema_itself_is_valid(self):
        Draft202012Validator.check_schema(SCHEMA)

    def test_both_examples_match_schema(self):
        for name in EXAMPLES:
            with self.subTest(name=name):
                example = load(name)
                VALIDATOR.validate(example)
                self.assertEqual(example["id"], name)

    def test_production_manifests_have_explicit_catalog_paths_and_match_fixtures(self):
        # T03-02/T03-03 are real catalog entries, not only schema examples.
        for name in EXAMPLES:
            with self.subTest(name=name):
                published = ROOT / name / "app.yaml"
                self.assertTrue(published.is_file())
                actual = yaml.safe_load(published.read_text(encoding="utf-8"))
                VALIDATOR.validate(actual)
                self.assertEqual(actual["id"], name)
                self.assertEqual(actual, load(name))
                self.assertEqual(actual["runtime"]["compose_project"], name)
                self.assertIn(f"{name}/deploy/docker-compose.yaml",
                              [f["destination"] for f in actual["package"]["files"]])
                self.assertIn("deploy/lib/image-sources.sh",
                              [f["destination"] for f in actual["package"]["files"]])

    def test_package_files_resolve_and_no_unsafe_destination(self):
        for name in EXAMPLES:
            app = load(name)
            names = set()
            for item in app["package"]["files"]:
                with self.subTest(name=name, file=item["source"]):
                    source = ROOT / item["source"]
                    self.assertTrue(source.is_file(), source)
                    self.assertFalse(source.is_symlink())
                    destination = item["destination"]
                    self.assertTrue(destination.startswith(name + "/") or
                                    destination.startswith("deploy/lib/"), destination)
                    self.assertNotIn(destination, names)
                    names.add(destination)
                    self.assertFalse(re.search(r"(^|/)(data|state|backup|runtime|workspace)(/|$)", destination))
                    self.assertFalse(destination.endswith("/.secrets"))
                    self.assertFalse(destination.endswith("/.env"))
            self.assertIn(name + "/" + app["runtime"]["compose_file"], names)
            for action in app["actions"].values():
                if action["strategy"] == "script":
                    self.assertIn(name + "/" + action["path"], names)

    def test_compose_projects_services_and_data_match_actual_files(self):
        for name in EXAMPLES:
            app = load(name)
            compose_path = ROOT / name / app["runtime"]["compose_file"]
            compose_text = compose_path.read_text(encoding="utf-8")
            compose = yaml.safe_load(compose_text)
            self.assertEqual(compose["name"], app["runtime"]["compose_project"])
            for service in app["verification"]["required_services"]:
                self.assertIn(service, compose["services"])
            config_by_key = {item["key"]: item for item in app["config"]}
            self.assertEqual(len(config_by_key), len(app["config"]))
            for port in app["ports"]:
                with self.subTest(name=name, port=port["id"]):
                    self.assertEqual(config_by_key[port["host_port_key"]]["type"], "port")
                    self.assertIn(port["host_port_key"], compose_text)
                    self.assertIn(port["service"], compose["services"])
                    if port.get("bind_address_key"):
                        self.assertEqual(config_by_key[port["bind_address_key"]]["type"], "ipv4")
                        self.assertIn(port["bind_address_key"], compose_text)
                    declared = compose["services"][port["service"]].get("ports", [])
                    self.assertTrue(any(str(port["container_port"]) in str(p) for p in declared))
            mounts = set()
            for container in compose["services"].values():
                for volume in container.get("volumes", []):
                    source = volume.split(":")[0] if isinstance(volume, str) else volume.get("source", "")
                    if source.startswith("../"):
                        mounts.add(posixpath.normpath(posixpath.join(name, "deploy", source)))
            for data_path in app["data"]["paths"]:
                self.assertIn(data_path, mounts)

    def test_secret_locations_match_existing_global_templates(self):
        env = (ROOT / ".env.example").read_text(encoding="utf-8")
        secrets = (ROOT / ".secrets.example").read_text(encoding="utf-8")
        for name in EXAMPLES:
            app = load(name)
            for field in app["config"]:
                with self.subTest(name=name, key=field["key"]):
                    target = secrets if field["target"] == "secrets" else env
                    self.assertRegex(target, rf"(?m)^{re.escape(field['key'])}=")
                    if field["type"] == "secret":
                        self.assertEqual(field["target"], "secrets")
                    if field.get("generated_by_script"):
                        self.assertIn(field["key"], (ROOT / name / "deploy/install.sh").read_text(encoding="utf-8"))

    def test_rejects_bad_paths_unknown_fields_and_plaintext_secret_defaults(self):
        valid = load("portainer")
        bad = copy.deepcopy(valid)
        bad["package"]["files"][0]["destination"] = "../escape"
        with self.assertRaises(ValidationError):
            VALIDATOR.validate(bad)
        bad = copy.deepcopy(valid)
        bad["not_an_application_field"] = True
        with self.assertRaises(ValidationError):
            VALIDATOR.validate(bad)
        bad = copy.deepcopy(valid)
        secret = next(f for f in bad["config"] if f["type"] == "secret")
        secret["default"] = "unsafe-password"
        with self.assertRaises(ValidationError):
            VALIDATOR.validate(bad)


if __name__ == "__main__":
    unittest.main()
