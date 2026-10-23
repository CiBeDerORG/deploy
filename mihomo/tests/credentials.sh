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

fail() { printf 'Credential regression failed: %s\n' "$1" >&2; exit 1; }

# Every documented optional-secret group accepts the same empty/omitted forms.
# An unrelated credential has punctuation, quotes, whitespace and non-ASCII;
# its record must survive generation, including when it lacked a final newline.
for key in MIHOMO_API_SECRET MIHOMO_CONTROL_TOKEN MIHOMO_PROXY_PASSWORD; do
    for form in raw double single key_space leading_space crlf omitted no_final_newline; do
        unset MIHOMO_API_SECRET MIHOMO_CONTROL_TOKEN MIHOMO_PROXY_PASSWORD
        printf 'UNRELATED=%s\n' "$pw" > "$SECRETS_FILE"
        case "$form" in
            raw) printf '%s=\n' "$key" >> "$SECRETS_FILE" ;;
            double) printf '%s=""\n' "$key" >> "$SECRETS_FILE" ;;
            single) printf "%s=''\n" "$key" >> "$SECRETS_FILE" ;;
            key_space) printf '%s =""\n' "$key" >> "$SECRETS_FILE" ;;
            leading_space) printf '  %s=\n' "$key" >> "$SECRETS_FILE" ;;
            crlf) printf '%s=\r\n' "$key" >> "$SECRETS_FILE" ;;
            omitted) printf 'UNRELATED=%s' "$pw" > "$SECRETS_FILE" ;;
            no_final_newline) printf '%s=' "$key" >> "$SECRETS_FILE" ;;
        esac
        read_pairs "$SECRETS_FILE"
        secret_when_blank "$key" >/dev/null
        generated="${!key}"
        [[ "$generated" =~ ^[a-f0-9]{64}$ ]] || fail "$key / $form did not generate"
        IFS= read -r unrelated < "$SECRETS_FILE"
        [[ "$unrelated" == "UNRELATED=$pw" ]] || fail "$key / $form changed another value"
        [[ "$(stat -c '%a' "$SECRETS_FILE")" == 600 ]] || fail 'Generated file is not private'
        cp "$SECRETS_FILE" "$tmp/after-generation"
        unset "$key"
        read_pairs "$SECRETS_FILE"
        [[ "${!key}" == "$generated" ]] || fail "$key / $form did not reload"
        secret_when_blank "$key" >/dev/null
        cmp -s "$SECRETS_FILE" "$tmp/after-generation" || fail "$key / $form rotated on reinstall"
    done
done

# Nonempty credentials retain their exact decoded value and original file bytes.
# Deliberately clear the variable afterwards: persistence rechecks disk rather
# than treating a stale empty environment as permission to replace a real value.
for key in MIHOMO_API_SECRET MIHOMO_CONTROL_TOKEN MIHOMO_PROXY_PASSWORD; do
    for form in raw double single crlf; do
        case "$form" in
            raw) printf '  %s =%s' "$key" "$pw" > "$SECRETS_FILE" ;;
            double) printf '%s="%s"\n' "$key" "$pw" > "$SECRETS_FILE" ;;
            single) printf "%s='%s'\n" "$key" "$pw" > "$SECRETS_FILE" ;;
            crlf) printf '%s=%s\r\n' "$key" "$pw" > "$SECRETS_FILE" ;;
        esac
        cp "$SECRETS_FILE" "$tmp/before-existing"
        read_pairs "$SECRETS_FILE"
        [[ "${!key}" == "$pw" ]] || fail "$key / $form did not preserve decoding"
        printf -v "$key" '%s' ''
        secret_when_blank "$key" >/dev/null
        [[ "${!key}" == "$pw" ]] || fail "$key / $form replaced a configured value"
        cmp -s "$SECRETS_FILE" "$tmp/before-existing" || fail 'Nonempty file was rewritten'
    done
done
# A whitespace-only password is nonempty credential data, not an optional blank.
printf 'MIHOMO_API_SECRET=   \n' > "$SECRETS_FILE"
read_pairs "$SECRETS_FILE"
secret_when_blank MIHOMO_API_SECRET >/dev/null
[[ "$MIHOMO_API_SECRET" == '   ' ]] || fail 'Whitespace credential was normalized'

# Ambiguous duplicates fail before writing, in both the loader and persistence
# helper, irrespective of ordering or whitespace around the variable name.
for order in filled_first empty_first both_filled; do
    case "$order" in
        filled_first) printf 'MIHOMO_API_SECRET=%s\n  MIHOMO_API_SECRET =\n' "$pw" > "$SECRETS_FILE" ;;
        empty_first) printf 'MIHOMO_API_SECRET=\nMIHOMO_API_SECRET =%s\n' "$pw" > "$SECRETS_FILE" ;;
        both_filled) printf 'MIHOMO_API_SECRET=%s\nMIHOMO_API_SECRET=%s\n' "$pw" "$pw" > "$SECRETS_FILE" ;;
    esac
    cp "$SECRETS_FILE" "$tmp/before-duplicate"
    if (read_pairs "$SECRETS_FILE") > "$tmp/error-log" 2>&1; then fail 'Loader accepted duplicate'; fi
    [[ "$(cat "$tmp/error-log")" != *"$pw"* ]] || fail 'Loader printed a value'
    if (MIHOMO_API_SECRET=; secret_when_blank MIHOMO_API_SECRET) > "$tmp/error-log" 2>&1; then
        fail 'Generator accepted duplicate'
    fi
    [[ "$(cat "$tmp/error-log")" != *"$pw"* ]] || fail 'Generator printed a value'
    cmp -s "$SECRETS_FILE" "$tmp/before-duplicate" || fail 'Duplicate file was changed'
done
printf 'MIHOMO_API_SECRET=%s\n' "$pw" > "$tmp/.env"
printf 'MIHOMO_API_SECRET=\n' > "$SECRETS_FILE"
if (read_pairs "$tmp/.env" "$SECRETS_FILE") > "$tmp/error-log" 2>&1; then
    fail 'Loader accepted a duplicate across .env and .secrets'
fi
# A failed atomic replacement must leave the original file intact and clean up
# staging; no generated value may be reported as successfully persisted.
printf 'MIHOMO_API_SECRET=""\n' > "$SECRETS_FILE"
cp "$SECRETS_FILE" "$tmp/before-write-failure"
if (
    MIHOMO_API_SECRET=
    mv() { return 1; }
    secret_when_blank MIHOMO_API_SECRET
) > "$tmp/error-log" 2>&1; then
    fail 'Generator ignored failed persistence'
fi
cmp -s "$SECRETS_FILE" "$tmp/before-write-failure" || fail 'Failed persistence damaged the original'
for staged in "${SECRETS_FILE}".tmp.*; do
    [ ! -e "$staged" ] || fail 'Failed persistence left a staged secret file'
done

# Exercise the production global template synchronizer without sourcing the
# deploy entrypoint, invoking sudo, or touching any real configuration directory.
awk '/^sync_template_keys\(\) \{/ { copying=1 } copying { print } copying && /^}$/ { exit }' \
    "$HERE/../../deploy.sh" > "$tmp/template-functions.sh"
source "$tmp/template-functions.sh"
run_root() { "$@"; }
SOFTWARE_ROOT=/review/requested-root
for spelling in MIHOMO_API_SECRET 'MIHOMO_API_SECRET ' '  MIHOMO_API_SECRET'; do
    printf 'SOFTWARE_ROOT=/review/existing-root\n%s=%s\n  SUB2API_JWT_SECRET =%s' \
        "$spelling" "$pw" "$pw" > "$SECRETS_FILE"
    before="$(cat "$SECRETS_FILE")"
    # Unterminated templates must not silently omit their final setting.
    printf 'SOFTWARE_ROOT=/template-default\nMIHOMO_API_SECRET=\nSUB2API_JWT_SECRET=\nNEW_OPTION=default' > "$tmp/template"
    GLOBAL_ENV_UPDATED=0
    sync_template_keys "$tmp/template" "$SECRETS_FILE" .secrets >/dev/null
    [[ "$GLOBAL_ENV_UPDATED" == 1 ]] || fail 'Missing template key was not added'
    [[ "$(cat "$SECRETS_FILE")" == "$before"* ]] || fail 'Synchronizer changed an existing record'
    grep -Fx 'NEW_OPTION=default' "$SECRETS_FILE" >/dev/null || fail 'Final template line was skipped'
    read_pairs "$SECRETS_FILE"
    [[ "$MIHOMO_API_SECRET" == "$pw" ]] || fail 'Synchronizer hid a configured credential'
    cp "$SECRETS_FILE" "$tmp/after-sync"
    secret_when_blank MIHOMO_API_SECRET >/dev/null
    sync_template_keys "$tmp/template" "$SECRETS_FILE" .secrets >/dev/null
    cmp -s "$SECRETS_FILE" "$tmp/after-sync" || fail 'Sync and generation were not idempotent'
done
printf 'NEW_OPTION=default\nMIHOMO_API_SECRET=\n' > "$tmp/template"
printf 'MIHOMO_API_SECRET=%s\n  MIHOMO_API_SECRET =\n' "$pw" > "$SECRETS_FILE"
cp "$SECRETS_FILE" "$tmp/before-sync-duplicate"
if (sync_template_keys "$tmp/template" "$SECRETS_FILE" .secrets) > "$tmp/error-log" 2>&1; then
    fail 'Synchronizer accepted duplicate target keys'
fi
[[ "$(cat "$tmp/error-log")" != *"$pw"* ]] || fail 'Synchronizer printed a value'
cmp -s "$SECRETS_FILE" "$tmp/before-sync-duplicate" || fail 'Synchronizer wrote before duplicate validation'
printf 'NEW_OPTION=default\nNEW_OPTION=another\n' > "$tmp/template"
printf 'MIHOMO_API_SECRET=%s\n' "$pw" > "$SECRETS_FILE"
cp "$SECRETS_FILE" "$tmp/before-sync-duplicate"
if (sync_template_keys "$tmp/template" "$SECRETS_FILE" .secrets) > "$tmp/error-log" 2>&1; then
    fail 'Synchronizer accepted duplicate template keys'
fi
cmp -s "$SECRETS_FILE" "$tmp/before-sync-duplicate" || fail 'Duplicate template partially applied'

# The CLI calls ensure_global_env in an OR-list, which disables Bash errexit
# inside functions. A rejected duplicate must still prevent later migrations.
awk '/^ensure_global_env\(\) \{/ { copying=1 } copying { print } copying && /^}$/ { exit }' \
    "$HERE/../../deploy.sh" > "$tmp/ensure-functions.sh"
if (
    source "$tmp/ensure-functions.sh"
    SOFTWARE_ROOT="$tmp/fake-root"
    GLOBAL_ENV_DIR="$SOFTWARE_ROOT/deploy"
    GLOBAL_ENV="$GLOBAL_ENV_DIR/.env"
    GLOBAL_SECRETS="$GLOBAL_ENV_DIR/.secrets"
    GLOBAL_ENV_EXAMPLE="$tmp/env-template"
    GLOBAL_SECRETS_EXAMPLE="$tmp/secrets-template"
    GLOBAL_ENV_CREATED=0
    GLOBAL_SECRETS_CREATED=0
    GLOBAL_ENV_UPDATED=0
    mkdir -p "$GLOBAL_ENV_DIR"
    printf 'MIHOMO_API_SECRET=%s\n  MIHOMO_API_SECRET =\n' "$pw" > "$GLOBAL_ENV"
    printf '# fake empty secrets\n' > "$GLOBAL_SECRETS"
    printf 'TZ=UTC\n' > "$GLOBAL_ENV_EXAMPLE"
    printf 'MIHOMO_API_SECRET=\n' > "$GLOBAL_SECRETS_EXAMPLE"
    migrate_global_env_path() { :; }
    migrate_easytier_default_ports() { touch "$tmp/migration-ran"; }
    migrate_flatnas_default_port() { :; }
    migrate_sensitive_env_keys() { :; }
    remove_deprecated_env_keys() { :; }
    run_root() { case "$1" in chown|chmod) return 0 ;; esac; "$@"; }
    ensure_global_env
) > "$tmp/error-log" 2>&1; then
    fail 'Global initialization swallowed a sync failure'
fi
[ ! -e "$tmp/migration-ran" ] || fail 'Migrations ran after rejected config'
[[ "$(cat "$tmp/error-log")" != *"$pw"* ]] || fail 'Global initialization printed a value'
echo 'Credential preservation, optional generation, duplicate rejection and template sync passed'
