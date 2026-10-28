#!/usr/bin/env python3
"""Validate Deploy app.yaml v1 before publishing to EasyTier's trusted catalog.

Only validates metadata and repository files; never executes shell, docker or git.
The exact validated manifest and file digests are inputs for T03-07's immutable
package builder. Schema success alone must NEVER imply execution permission.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import posixpath
import re
import stat
import sys
from pathlib import Path, PurePosixPath

import yaml
from jsonschema import Draft202012Validator, FormatChecker

DEFAULT_ROOT = Path(__file__).resolve().parents[1]
BLOCKED_PARTS = {"data", "state", "backup", "runtime", "workspace"}
BLOCKED_NAMES = {".env", ".secrets", ".git", ".ssh", "id_rsa", "id_ed25519"}
MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_PACKAGE_BYTES = 24 * 1024 * 1024
COMPOSE_VAR = re.compile(r"\$\{([A-Z][A-Z0-9_]*)(?::[^}]*)?\}")
ALLOWED_SCRIPT_ARGS = {"install": {"install"}, "update": {"update"}, "uninstall": set()}


class ManifestError(ValueError):
    """Fail closed; messages contain relative locations, never secret values."""


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def _mapping(loader: UniqueKeyLoader, node: yaml.nodes.MappingNode):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, (str, int, float, bool)) or key in result:
            raise ManifestError("Duplicate or unsupported YAML mapping key")
        result[key] = loader.construct_object(value_node)
    return result


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping
)


def yaml_load(path: Path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return yaml.load(handle, Loader=UniqueKeyLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise ManifestError(f"Cannot read YAML: {path.name}: {type(exc).__name__}") from exc


def require(ok: bool, detail: str):
    if not ok:
        raise ManifestError(detail)


def safe_parts(raw: str, field: str, *, allow_shared: bool = True) -> tuple[str, ...]:
    require(isinstance(raw, str) and 0 < len(raw) <= 256,
            f"{field}: path must be a nonempty string of at most 256 characters")
    require(not raw.startswith("/") and "\\" not in raw and "\x00" not in raw,
            f"{field}: absolute, backslash or NUL path forbidden")
    pieces = raw.split("/")
    require(all(piece not in ("", ".", "..") for piece in pieces),
            f"{field}: empty/dot/traversal path forbidden")
    require(all(re.fullmatch(r"[A-Za-z0-9_.-]+", piece) for piece in pieces),
            f"{field}: unsafe characters")
    require(not any(piece.startswith(".") or piece.lower() in BLOCKED_NAMES for piece in pieces),
            f"{field}: hidden file or credential path forbidden")
    if not allow_shared:
        require(not any(piece.casefold() in BLOCKED_PARTS for piece in pieces),
                f"{field}: protected data directory forbidden")
    return tuple(pieces)


def verified_file(root: Path, source: str) -> Path:
    pieces = safe_parts(source, "package.source", allow_shared=False)
    current = root
    for piece in pieces:
        current = current / piece
        require(not current.is_symlink(), f"package.source: symlink forbidden: {source}")
    try:
        meta = os.lstat(current)
    except OSError as exc:
        raise ManifestError(f"package.source does not exist: {source}") from exc
    require(stat.S_ISREG(meta.st_mode), f"package.source is not a regular file: {source}")
    require(meta.st_size <= MAX_FILE_BYTES, f"package.source oversized: {source}")
    return current


def compose_port_match(entry, declared: dict) -> bool:
    """Compare exact Compose host IP, variable and target port; ignore ':' inside ${VAR:?error}."""
    key = declared["host_port_key"]
    target = int(declared["container_port"])
    protocol = declared["protocol"]
    bind = declared.get("bind_address_key")
    if isinstance(entry, str):
        variable = lambda k: r"\\$\\{" + re.escape(k) + r"(?::[^}]*)?\\}"
        host = variable(key)
        ip = variable(bind) + ":" if bind else ""
        return re.fullmatch(ip + host + ":" + str(target) + r"(?:/" + protocol + r")?",
                            entry) is not None
    if isinstance(entry, dict):
        if str(entry.get("target")) != str(target) or entry.get("protocol", "tcp") != protocol:
            return False
        return key in COMPOSE_VAR.findall(str(entry.get("published", ""))) and (
            not bind or bind in COMPOSE_VAR.findall(str(entry.get("host_ip", ""))
        )
    return False

def validate(manifest: Path, root: Path = DEFAULT_ROOT, schema_path: Path | None = None) -> dict:
    root = root.resolve(strict=True)
    schema_path = schema_path or root / "schema/app-manifest-v1.schema.json"
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
    except (OSError, ValueError, Exception) as exc:
        raise ManifestError(f"Schema unavailable or invalid: {type(exc).__name__}") from exc
    data = yaml_load(manifest)
    require(isinstance(data, dict), "Manifest must be a mapping")
    validation_errors = sorted(
        Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(data),
        key=lambda item: [str(x) for x in item.absolute_path],
    )
    if validation_errors:
        err = validation_errors[0]
        location = ".".join(str(i) for i in err.absolute_path) or "root"
        # Avoid echoing secret default values from validator diagnostics.
        raise ManifestError(f"Schema validation failed at {location}: {err.validator}")
    app = data["id"]
    # Contract fixtures live under schema/examples; production must be <id>/app.yaml.
    is_fixture = (manifest.parent.resolve() == (root / "schema/examples").resolve()
                  and manifest.name == f"{app}.app.yaml")
    if not is_fixture:
        require(manifest.name == "app.yaml" and manifest.parent.resolve() == root / app,
                "Production manifest must be located exactly at <app-id>/app.yaml")

    files = {}
    src_keys, dest_keys = set(), set()
    total = 0
    for item in data["package"]["files"]:
        source, dest = item["source"], item["destination"]
        segments = safe_parts(dest, "package.destination", allow_shared=False)
        require((len(segments) >= 2 and segments[0] == app) or
                (len(segments) >= 3 and segments[:2] == ("deploy", "lib")),
                f"package.destination outside application/shared library: {dest}")
        require(dest.casefold() not in dest_keys and source.casefold() not in src_keys,
                "Duplicate package source or destination, including case-only collisions")
        dest_keys.add(dest.casefold())
        src_keys.add(source.casefold())
        require(source.startswith(app + "/") or source.startswith("lib/"),
                f"package.source outside application/shared library: {source}")
        if dest.startswith("deploy/lib/"):
            require(source == dest.removeprefix("deploy/"),
                    "Shared library destinations must preserve lib/ source paths")
        else:
            require(source == dest, "Application package destination must retain source path")
        file_path = verified_file(root, source)
        total += file_path.stat().st_size
        require(total <= MAX_PACKAGE_BYTES, "Package files exceed maximum aggregate size")
        files[dest] = file_path

    compose_rel = app + "/" + data["runtime"]["compose_file"]
    require(compose_rel in files, f"Compose file absent from package: {compose_rel}")
    compose = yaml_load(files[compose_rel])
    require(isinstance(compose, dict) and isinstance(compose.get("services"), dict)
            and bool(compose["services"]), "Compose must define services")
    require(compose.get("name") == data["runtime"]["compose_project"],
            "Compose project name does not match runtime.compose_project")
    services = compose["services"]
    for service, detail in services.items():
        require(isinstance(service, str) and isinstance(detail, dict),
                "Compose services must be named mappings")
    require(set(data["verification"]["required_services"]) <= set(services),
            "Verification references missing Compose services")
    if data["verification"]["state"] == "healthy":
        for name in data["verification"]["required_services"]:
            require("healthcheck" in services[name],
                    f"Healthy verification requires a Compose healthcheck: {name}")

    config = {}
    for field in data["config"]:
        key = field["key"]
        require(key not in config, f"Duplicate config key: {key}")
        config[key] = field
        require((field["type"] == "secret") == (field["target"] == "secrets"),
                f"Config secret target mismatch: {key}")
        if field["type"] == "secret":
            require("default" not in field or field["default"] == "",
                    f"Secret default must be blank: {key}")
        if field.get("generated_by_script"):
            require(field["type"] == "secret", f"Auto-generation limited to secrets: {key}")
            install_action = data["actions"]["install"]
            require(install_action["strategy"] == "script",
                    "Generated secret needs a real install script")
            script_dest = app + "/" + install_action["path"]
            require(script_dest in files, "Generated secret install script missing")
            text = files[script_dest].read_text(encoding="utf-8")
            require(re.search(r"\b" + re.escape(key) + r"\b", text) is not None
                    and ("ensure_hex_secret" in text or "generate" in text),
                    f"Generated secret has no observable implementation: {key}")
        if "min_length" in field and "max_length" in field:
            require(field["min_length"] <= field["max_length"],
                    f"Invalid string length constraints: {key}")
        if "minimum" in field and "maximum" in field:
            require(field["minimum"] <= field["maximum"],
                    f"Invalid numeric range constraints: {key}")
        default = field.get("default")
        if default is not None and field["type"] == "port":
            require(isinstance(default, int) and not isinstance(default, bool)
                    and 1 <= default <= 65535
                    and field.get("minimum", 1) <= default <= field.get("maximum", 65535),
                    f"Invalid port default: {key}")
        elif default is not None and field["type"] == "ipv4":
            try:
                ipaddress.IPv4Address(default)
            except (ValueError, TypeError) as exc:
                raise ManifestError(f"Invalid IPv4 default: {key}") from exc
        elif default is not None and field["type"] == "number":
            require(isinstance(default, int) and not isinstance(default, bool),
                    f"Invalid numeric default: {key}")
        elif default is not None and field["type"] == "boolean":
            require(isinstance(default, bool), f"Invalid boolean default: {key}")

    port_ids = set()
    for port in data["ports"]:
        require(port["id"] not in port_ids, f"Duplicate port ID: {port['id']}")
        port_ids.add(port["id"])
        key = port["host_port_key"]
        require(key in config and config[key]["type"] == "port",
                f"Port references missing/wrong-type variable: {key}")
        bind = port.get("bind_address_key")
        require(not bind or (bind in config and config[bind]["type"] == "ipv4"),
                f"Bind address references missing/wrong-type variable: {bind}")
        service = port.get("service")
        require(service in services, f"Port references unknown Compose service: {service}")
        declared = services[service].get("ports", [])
        require(isinstance(declared, list) and any(compose_port_match(e, port) for e in declared),
                f"Compose port mapping absent or mismatched: {port['id']}")

    for action_name, action in data["actions"].items():
        strategy = action["strategy"]
        require((strategy == "script" and action_name != "uninstall") or
                (strategy == "compose_down" and action_name == "uninstall"),
                f"Action strategy not allowed in v1: {action_name}")
        require(not action.get("remove_orphans"), "Removing orphan containers not authorized in v1")
        argv = action.get("argv", [])
        require(len(argv) <= 1 and all(a in ALLOWED_SCRIPT_ARGS[action_name] for a in argv),
                f"Unapproved script arguments: {action_name}")
        if strategy == "script":
            script_dest = app + "/" + action["path"]
            require(script_dest in files, f"Action script not included in package: {action_name}")
            require(action["path"].endswith(".sh"), f"Non-shell script unsupported: {action_name}")
            require("0755" == next((f.get("mode", "0644") for f in data["package"]["files"]
                                    if f["destination"] == script_dest), None),
                    f"Script is not marked executable: {action_name}")
            actual = files[script_dest].read_text(encoding="utf-8")
            # Existing scripts discover their common dependencies at runtime.
            if "deploy/lib/image-sources.sh" in actual:
                require("deploy/lib/image-sources.sh" in files,
                        "Shared image-sources.sh dependency missing from package")

    mounts = set()
    for service in services.values():
        for vol in service.get("volumes", []):
            if isinstance(vol, str):
                source = vol.split(":", 1)[0]
            elif isinstance(vol, dict):
                source = vol.get("source", "")
            else:
                continue
            if source.startswith("../"):
                normalized = posixpath.normpath(posixpath.join(app,
                    posixpath.dirname(data["runtime"]["compose_file"]), source))
                mounts.add(normalized)
    for entry in data["data"]["paths"]:
        parts = safe_parts(entry, "data.paths")
        require(parts[0] == app and len(parts) >= 2 and "data" in parts,
                f"Data path must be under the application's data directory: {entry}")
        require(entry in mounts, f"Data path absent from Compose bind mounts: {entry}")
    require(data["data"].get("default_retain") is True,
            "Uninstall must retain user data by default")

    env_text = (root / ".env.example").read_text(encoding="utf-8")
    secret_text = (root / ".secrets.example").read_text(encoding="utf-8")
    for field in data["config"]:
        target = secret_text if field["type"] == "secret" else env_text
        require(re.search(r"(?m)^" + re.escape(field["key"]) + r"=", target) is not None,
                f"Config key missing from shared example template: {field['key']}")

    primary = next((p["id"] for p in data["ports"] if p["purpose"] == "web"),
                   data["ports"][0]["id"] if data["ports"] else None)
    return {
        "id": app,
        "compose_project": data["runtime"]["compose_project"],
        "package_file_count": len(files),
        "primary_port_id": primary,
        "required_services": data["verification"]["required_services"],
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifests", nargs="*", type=Path,
                        help="One or more <id>/app.yaml or schema/examples/<id>.app.yaml")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--examples", action="store_true",
                        help="Validate both contract examples in this checkout")
    parser.add_argument("--all", action="store_true",
                        help="Validate every published <id>/app.yaml (does not load examples)")
    args = parser.parse_args(argv)
    paths = list(args.manifests)
    if args.examples:
        paths += sorted((args.root / "schema/examples").glob("*.app.yaml"))
    if args.all:
        paths += sorted(p for p in args.root.glob("*/app.yaml") if p.is_file())
    if not paths:
        parser.error("Supply manifests or use --examples / --all")
    failed = False
    for path in paths:
        try:
            result = validate(path, args.root)
            print(json.dumps({"manifest": str(path), "valid": True, **result},
                             ensure_ascii=False, sort_keys=True))
        except ManifestError as exc:
            failed = True
            print(json.dumps({"manifest": str(path), "valid": False, "error": str(exc)},
                             ensure_ascii=False), file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
