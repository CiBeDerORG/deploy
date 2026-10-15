#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../deploy/lib.sh
source "$HERE/../deploy/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
SECRETS_FILE="$work/.secrets"
# Every optional runtime secret has a different valid blank representation.
cat > "$SECRETS_FILE" <<'EOF_INPUT'
SUB2API_POSTGRES_PASSWORD=
SUB2API_REDIS_PASSWORD=""
SUB2API_JWT_SECRET=''
SUB2API_TOTP_ENCRYPTION_KEY =
EOF_INPUT
load_dotenv_file "$SECRETS_FILE"
for key in SUB2API_POSTGRES_PASSWORD SUB2API_REDIS_PASSWORD SUB2API_JWT_SECRET SUB2API_TOTP_ENCRYPTION_KEY; do
    [ -z "${!key:-}" ] || { echo "Expected blank input: $key" >&2; exit 1; }
    ensure_hex_secret "$key"
    [[ "${!key}" =~ ^[a-f0-9]{64}$ ]] || { echo "Missing generated value: $key" >&2; exit 1; }
    grep -Fx "$key=${!key}" "$SECRETS_FILE" >/dev/null
done
before="$(cat "$SECRETS_FILE")"
for key in SUB2API_POSTGRES_PASSWORD SUB2API_REDIS_PASSWORD SUB2API_JWT_SECRET SUB2API_TOTP_ENCRYPTION_KEY; do
    original="${!key}"
    ensure_hex_secret "$key"
    [[ "${!key}" == "$original" ]]
done
[[ "$(cat "$SECRETS_FILE")" == "$before" ]] || { echo 'Existing secrets were rotated' >&2; exit 1; }

# A missing key is also optional, generated and persisted on first install.
: > "$SECRETS_FILE"
unset SUB2API_POSTGRES_PASSWORD
ensure_hex_secret SUB2API_POSTGRES_PASSWORD
[[ "$SUB2API_POSTGRES_PASSWORD" =~ ^[a-f0-9]{64}$ ]]
grep -Fx "SUB2API_POSTGRES_PASSWORD=$SUB2API_POSTGRES_PASSWORD" "$SECRETS_FILE" >/dev/null

# Last-value semantics with duplicate keys are ambiguous: never overwrite
# an earlier nonempty user credential when a later empty line appears.
cat > "$SECRETS_FILE" <<'EOF_DUPLICATE'
SUB2API_JWT_SECRET=ExistingCustomValue
SUB2API_JWT_SECRET=""
EOF_DUPLICATE
SUB2API_JWT_SECRET=
cp "$SECRETS_FILE" "$work/before-duplicate"
if (ensure_hex_secret SUB2API_JWT_SECRET) >/dev/null 2>&1; then
    echo 'Duplicate definition must fail without rotating existing value' >&2; exit 1
fi
cmp "$SECRETS_FILE" "$work/before-duplicate"

# Upstream independently generates a missing ADMIN_EMAIL and ADMIN_PASSWORD;
# our installer must not invent a both-or-neither precondition.
grep -F 'if [ -n "$SUB2API_ADMIN_PASSWORD" ]; then' "$HERE/../deploy/install.sh" >/dev/null
if grep -Fq '后台账号和密码必须同时填写' "$HERE/../deploy/install.sh"; then
    echo 'Optional admin inputs were incorrectly coupled' >&2; exit 1
fi
echo 'Sub2API optional input, persisted generation, and preservation checks passed.'
