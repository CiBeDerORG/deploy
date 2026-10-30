#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ENV_FILE="$TMP/.env"
SECRETS_FILE="$TMP/.secrets"
# shellcheck source=../deploy/lib.sh
source "$ROOT/openhands/deploy/lib.sh"

printf '%s\n' 'OPENHANDS_PORT=7016' 'OPENHANDS_BIND_IP=0.0.0.0' > "$ENV_FILE"
printf '%s\n' 'OTHER_SECRET=preserved' 'OPENHANDS_API_KEY= ""' > "$SECRETS_FILE"
load_config
[ -z "$OPENHANDS_API_KEY" ] || fail "quoted empty not interpreted as empty"
OPENHANDS_API_KEY='generated-for-test'
persist_generated_api_key
grep -qx 'OPENHANDS_API_KEY=generated-for-test' "$SECRETS_FILE"
grep -qx 'OTHER_SECRET=preserved' "$SECRETS_FILE"
[ "$(grep -c '^OPENHANDS_API_KEY=' "$SECRETS_FILE")" -eq 1 ]
load_config
[ "$OPENHANDS_API_KEY" = 'generated-for-test' ] || fail "generated key lost on reload"

# Preserve user-chosen credentials with quotes, punctuation and non-ASCII.
printf '%s\n' 'OPENHANDS_API_KEY="  密钥 !@#$() '\''quoted'\''  "' > "$SECRETS_FILE"
load_config
[ "$OPENHANDS_API_KEY" = "  密钥 !@#\$() 'quoted'  " ] || fail "custom key altered"
grep -q '密钥' "$SECRETS_FILE" || fail "custom value file altered"

# Quoted single- and double-empty values are optional, not errors.
printf '%s\n' "OPENHANDS_API_KEY=''" > "$SECRETS_FILE"
load_config
[ -z "$OPENHANDS_API_KEY" ] || fail "single quoted empty is nonempty"
printf '%s\n' 'OTHER_SECRET=still-here' > "$SECRETS_FILE"
unset OPENHANDS_API_KEY
load_config
[ -z "${OPENHANDS_API_KEY:-}" ] || fail "omitted key is nonempty"

# A duplicate must be rejected instead of choosing an arbitrary token.
printf '%s\n' 'OPENHANDS_API_KEY=a' 'OPENHANDS_API_KEY=b' > "$SECRETS_FILE"
if (load_config) >/dev/null 2>&1; then fail "duplicate API key was accepted"; fi
printf '%s\n' 'OPENHANDS_API_KEY=bad' > "$ENV_FILE"
if (load_config) >/dev/null 2>&1; then fail "secret in .env was accepted"; fi

echo "OpenHands config / secret persistence regression passed"
