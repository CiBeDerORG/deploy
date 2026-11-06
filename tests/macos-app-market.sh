#!/usr/bin/env bash
# Run with Apple's built-in Bash 3.2 on macOS; exercise the same helpers used by
# the existing Linux app install/update/uninstall scripts.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export EASYHOSTAGENT_PLATFORM=macos
source "$ROOT_DIR/lib/platform.sh"
deploy_require_root

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# BSD sed -i syntax and user-owned 0600 configuration files.
printf 'before\r\n' > "$TMP_ROOT/config.env"
deploy_sed_in_place 's/\r$//' "$TMP_ROOT/config.env"
[[ "$(cat "$TMP_ROOT/config.env")" == before ]]
deploy_secure_config_files "$TMP_ROOT/config.env"
[[ "$(stat -f '%Lp' "$TMP_ROOT/config.env")" == 600 ]]
deploy_chown_if_needed root:wheel "$TMP_ROOT/config.env"

# The image mirror selector must work with Bash 3.2 and without util-linux flock.
mkdir -p "$TMP_ROOT/images/deploy"
cat > "$TMP_ROOT/images/deploy/.env" <<'EOF_ENV'
DOCKER_IMAGE_SOURCE=mirror
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy,dockerproxy
EOF_ENV
source "$ROOT_DIR/lib/image-sources.sh"
DEPLOY_TEST_IMAGE=ghcr.io/cibeder/example:latest
deploy_prepare_images "$TMP_ROOT/images" "$TMP_ROOT/images/deploy/.env" DEPLOY_TEST_IMAGE
[[ "$DEPLOY_TEST_IMAGE" == ghcr.dockerproxy.net/cibeder/example:latest ]]
[[ "$(cat "$TMP_ROOT/images/deploy/state/image-mirror.last")" == dockerproxy ]]

# Exercise the existing Mihomo helper's duplicate-key parser without Docker.
ROOT="$TMP_ROOT/mihomo"
mkdir -p "$ROOT/deploy/lib"
cp "$ROOT_DIR/lib/platform.sh" "$ROOT/deploy/lib/platform.sh"
printf 'MIHOMO_API_PORT=7012\nTZ=Asia/Shanghai\n' > "$ROOT/deploy/.env"
printf 'MIHOMO_API_SECRET=\n' > "$ROOT/deploy/.secrets"
source "$ROOT_DIR/mihomo/deploy/common.sh"
load_settings "$ROOT"
secret_when_blank MIHOMO_API_SECRET
grep -Eq '^MIHOMO_API_SECRET=[a-f0-9]{64}$' "$ROOT/deploy/.secrets"

# Exercise the existing Qoder and Sub2API helpers with the current-user model.
SOFTWARE_ROOT="$TMP_ROOT/qoder"
mkdir -p "$SOFTWARE_ROOT/deploy/lib"
cp "$ROOT_DIR/lib/platform.sh" "$SOFTWARE_ROOT/deploy/lib/platform.sh"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
printf 'QODER2API_HUB_PORT=8790\nQODER2API_HUB_BIND_IP=127.0.0.1\n' > "$ENV_FILE"
printf 'QODER2API_HUB_API_KEY=test-key\n' > "$SECRETS_FILE"
source "$ROOT_DIR/qoder2api-hub/deploy/lib.sh"
load_global_config
[[ "$QODER2API_HUB_PORT" == 8790 ]]

SOFTWARE_ROOT="$TMP_ROOT/sub2api"
mkdir -p "$SOFTWARE_ROOT/deploy/lib"
cp "$ROOT_DIR/lib/platform.sh" "$SOFTWARE_ROOT/deploy/lib/platform.sh"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
printf 'SUB2API_HTTP_PORT=7010\nSUB2API_BIND_IP=127.0.0.1\n' > "$ENV_FILE"
printf 'SUB2API_POSTGRES_PASSWORD=\n' > "$SECRETS_FILE"
source "$ROOT_DIR/sub2api/deploy/lib.sh"
load_global_config
ensure_hex_secret SUB2API_POSTGRES_PASSWORD
grep -Eq '^SUB2API_POSTGRES_PASSWORD=[a-f0-9]{64}$' "$SECRETS_FILE"

# Every existing app lifecycle script must parse under macOS' system Bash.
for app in mihomo opencode portainer qoder2api-hub sub2api; do
    for file in "$ROOT_DIR/$app"/deploy/*.sh; do
        /bin/bash -n "$file"
    done
done
/bin/bash -n "$ROOT_DIR/lib/image-sources.sh"
echo "macOS app market lifecycle compatibility checks passed"
