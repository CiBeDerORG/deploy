#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../deploy/lib.sh
source "$SCRIPT_DIR/../deploy/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
SECRETS_FILE="$tmp/.secrets"
# User-entered password must be preserved, including YAML punctuation and apostrophes.
custom_password=$' Sp@ce: # $HOME "double" \\ O\'Reilly = 中文 '
printf 'MIHOMO_API_SECRET=short\nMIHOMO_PROXY_PASSWORD=%s\n' "$custom_password" > "$SECRETS_FILE"
load_dotenv_file "$SECRETS_FILE"
[[ "$MIHOMO_API_SECRET" == short ]]
[[ "$MIHOMO_PROXY_PASSWORD" == "$custom_password" ]]
before="$(cat "$SECRETS_FILE")"
ensure_hex_secret MIHOMO_API_SECRET
ensure_hex_secret MIHOMO_PROXY_PASSWORD
[[ "$(cat "$SECRETS_FILE")" == "$before" ]] || { echo 'Existing credentials must not change' >&2; exit 1; }
scalar="$(yaml_single_quote_scalar "deploy:$MIHOMO_PROXY_PASSWORD")"
python3 - "$custom_password" "$scalar" <<'PY'
import sys
expected, encoded = sys.argv[1:]
assert encoded.startswith("'") and encoded.endswith("'")
assert encoded[1:-1].replace("''", "'") == f"deploy:{expected}"
PY
# Empty values still opt in to the previously documented random generation.
printf 'MIHOMO_PROXY_PASSWORD=\n' > "$SECRETS_FILE"
MIHOMO_PROXY_PASSWORD=
ensure_hex_secret MIHOMO_PROXY_PASSWORD
[[ "$MIHOMO_PROXY_PASSWORD" =~ ^[a-f0-9]{64}$ ]]
grep -Fx "MIHOMO_PROXY_PASSWORD=$MIHOMO_PROXY_PASSWORD" "$SECRETS_FILE" >/dev/null
# A single quote must be doubled for a valid YAML single-quoted scalar.
[[ "$(yaml_single_quote_scalar "O'Reilly")" == "'O''Reilly'" ]]
echo 'Mihomo custom credential preservation passed.'
