#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../deploy/common.sh
source "$HERE/../deploy/common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
SECRETS_FILE="$tmp/.secrets"
# Existing global MYAI_IP must be imported without defining another option.
printf 'MYAI_IP=198.51.100.42\nOPENCODE_PORT=7003\n' > "$tmp/.env"
MYAI_IP=
read_pairs "$tmp/.env"
[[ "$MYAI_IP" == 198.51.100.42 ]]
cors="$(cors_yaml 7012)"
grep -Fx "    - 'http://198.51.100.42:7012'" <<< "$cors" >/dev/null
[[ "$cors" != *"198.51.100.42:7013"* ]]
unset MYAI_IP
cors="$(cors_yaml 7012)"
[[ "$cors" != *"198.51.100.42"* ]]
pw=$' My: # = $HOME "double" \\\\ O\'Reilly 中文 '
printf 'MIHOMO_API_SECRET=%s\nMIHOMO_PROXY_PASSWORD=%s\nMIHOMO_CONTROL_TOKEN=\n' "$pw" "$pw" > "$SECRETS_FILE"
read_pairs "$SECRETS_FILE"
[[ "$MIHOMO_API_SECRET" == "$pw" && "$MIHOMO_PROXY_PASSWORD" == "$pw" ]]
before="$(cat "$SECRETS_FILE")"
secret_when_blank MIHOMO_API_SECRET
secret_when_blank MIHOMO_PROXY_PASSWORD
[[ "$(cat "$SECRETS_FILE")" == "$before" ]] || { echo 'Configured password changed' >&2; exit 1; }
encoded="$(yaml_scalar "deploy:$pw")"
python3 - "$pw" "$encoded" <<'PY'
import sys
password, yaml = sys.argv[1:]
assert yaml.startswith("'") and yaml.endswith("'")
assert yaml[1:-1].replace("''", "'") == 'deploy:' + password
PY
secret_when_blank MIHOMO_CONTROL_TOKEN
[[ "$MIHOMO_CONTROL_TOKEN" =~ ^[a-f0-9]{64}$ ]]
grep -Fx "MIHOMO_CONTROL_TOKEN=$MIHOMO_CONTROL_TOKEN" "$SECRETS_FILE" >/dev/null
after="$(cat "$SECRETS_FILE")"
secret_when_blank MIHOMO_CONTROL_TOKEN
[[ "$(cat "$SECRETS_FILE")" == "$after" ]] || { echo 'Generated value rotated' >&2; exit 1; }
echo 'Fresh credential handling passed'
