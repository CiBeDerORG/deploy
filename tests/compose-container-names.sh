#!/usr/bin/env bash
# Ensure every Docker Compose service uses a stable, application-based container name.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

check_compose() {
    local label="$1"
    local expected="$2"
    local output="$TMP_DIR/$label.json"
    shift 2

    echo "Checking stable container names: $label"
    docker compose --env-file /dev/null "$@" config --no-interpolate --format json > "$output"

    python3 - "$label" "$expected" "$output" <<'PY'
import json
import sys
from pathlib import Path

label, expected_json, output_path = sys.argv[1:]
expected = json.loads(expected_json)
config = json.loads(Path(output_path).read_text())
services = config.get("services", {})

if set(services) != set(expected):
    raise SystemExit(
        f"{label}: services differ; expected={sorted(expected)}, actual={sorted(services)}"
    )

actual = {}
for service, definition in services.items():
    name = definition.get("container_name")
    if not isinstance(name, str) or not name.strip():
        raise SystemExit(f"{label}: service {service!r} has no explicit container_name")
    actual[service] = name

if actual != expected:
    raise SystemExit(f"{label}: container names differ; expected={expected}, actual={actual}")

if len(set(actual.values())) != len(actual):
    raise SystemExit(f"{label}: duplicate container names are not allowed: {actual}")

print(f"  OK: {actual}")
PY
}

cd "$ROOT_DIR"

check_compose easynettopo-linux '{"easynettopo":"easynettopo"}' \
    -f easynettopo/deploy/docker-compose.yaml

check_compose easynettopo-macos '{"easynettopo":"easynettopo"}' \
    -f easynettopo/deploy/docker-compose.yaml \
    -f easynettopo/deploy/docker-compose.macos.yaml

check_compose easytier-automation-executor '{"easytier-automation-executor":"easytier-automation-executor"}' \
    -f easytier-automation-executor/deploy/docker-compose.yaml

check_compose easytier '{"easytier":"easytier"}' \
    -f easytier/deploy/docker-compose.yaml

check_compose flatnas '{"flatnas":"flatnas"}' \
    -f flatnas/deploy/docker-compose.yaml

check_compose flatnas-socket '{"flatnas":"flatnas"}' \
    -f flatnas/deploy/docker-compose.yaml \
    -f flatnas/deploy/docker-compose.socket.yaml

check_compose frps '{"frps":"frps"}' \
    -f frps/deploy/docker-compose.yaml

check_compose mihomo '{"mihomo":"mihomo"}' \
    -f mihomo/deploy/docker-compose.yaml

check_compose opencode '{"opencode":"opencode"}' \
    -f opencode/deploy/docker-compose.yaml

check_compose openhands '{"openhands":"openhands"}' \
    -f openhands/deploy/docker-compose.yaml

check_compose portainer '{"portainer":"portainer"}' \
    -f portainer/deploy/docker-compose.yaml

check_compose qoder2api-hub '{"qoder2api-hub":"qoder2api-hub"}' \
    -f qoder2api-hub/deploy/docker-compose.yaml

check_compose sub2api '{"sub2api":"sub2api","postgres":"sub2api-postgres","redis":"sub2api-redis"}' \
    -f sub2api/deploy/docker-compose.yaml

check_compose webtop '{"webtop":"webtop"}' \
    -f webtop/deploy/docker-compose.yaml

echo "All application container names are explicit, stable, and unique."
