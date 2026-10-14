#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../deploy/lib.sh
source "$SCRIPT_DIR/../deploy/lib.sh"

assert_valid() {
    validate_upstream_admin_password "$1"
}
assert_invalid() {
    if (validate_upstream_admin_password "$1") >/dev/null 2>&1; then
        echo 'Expected upstream password validation failure' >&2
        exit 1
    fi
}

# Exactly mirror upstream's Go len(string): UTF-8 byte length, not characters.
assert_invalid "1234567"
assert_valid "12345678"
assert_valid "123456789012"
assert_valid "$(printf '%072d' 0)"
assert_invalid "$(printf '%073d' 0)"
assert_invalid "中文"   # six UTF-8 bytes
assert_valid "中文好"  # nine UTF-8 bytes
assert_valid "Aa: # $ ' \" 中文"
assert_invalid "$(printf '%069d' 0)中文"  # 75 bytes

# Preexisting nonempty custom secrets must survive initialization untouched.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
SECRETS_FILE="$tmp/.secrets"
custom="Aa: # dollar\$ apostrophe' \" double 中文"
printf 'SUB2API_POSTGRES_PASSWORD=%s\n' "$custom" > "$SECRETS_FILE"
printf 'SUB2API_REDIS_PASSWORD=%s\n' "$custom" >> "$SECRETS_FILE"
printf 'SUB2API_JWT_SECRET=%s\n' "$custom" >> "$SECRETS_FILE"
printf 'SUB2API_TOTP_ENCRYPTION_KEY=%s\n' "$custom" >> "$SECRETS_FILE"
printf 'SUB2API_ADMIN_PASSWORD=%s\n' "$custom" >> "$SECRETS_FILE"
load_dotenv_file "$SECRETS_FILE"
[[ "$SUB2API_ADMIN_PASSWORD" == "$custom" ]]
original="$(cat "$SECRETS_FILE")"
for key in SUB2API_POSTGRES_PASSWORD SUB2API_REDIS_PASSWORD SUB2API_JWT_SECRET SUB2API_TOTP_ENCRYPTION_KEY; do
    ensure_hex_secret "$key"
    [[ "${!key}" == "$custom" ]]
done
[[ "$(cat "$SECRETS_FILE")" == "$original" ]]

# Blank credentials are explicitly opted into generated values.
printf 'SUB2API_JWT_SECRET=\n' > "$SECRETS_FILE"
SUB2API_JWT_SECRET=
ensure_hex_secret SUB2API_JWT_SECRET
[[ "$SUB2API_JWT_SECRET" =~ ^[a-f0-9]{64}$ ]]
grep -Fx "SUB2API_JWT_SECRET=$SUB2API_JWT_SECRET" "$SECRETS_FILE" >/dev/null
echo 'Sub2API upstream password policy and credential preservation passed.'
