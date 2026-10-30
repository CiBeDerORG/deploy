#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "Webtop installer regression test requires root or sudo." >&2; exit 1; }
    exec sudo -- bash "$0" "$@"
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

SOFTWARE_ROOT="$TEMP_DIR/software"
FAKE_BIN="$TEMP_DIR/fake-bin"
APP_DIR="$SOFTWARE_ROOT/webtop"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
mkdir -p "$SOFTWARE_ROOT/deploy/lib" "$FAKE_BIN"
cp -a "$ROOT_DIR/webtop" "$APP_DIR"
cp "$ROOT_DIR/lib/image-sources.sh" "$SOFTWARE_ROOT/deploy/lib/image-sources.sh"

export WEBTOP_TEST_DOCKER_LOG="$TEMP_DIR/docker.log"
export WEBTOP_TEST_CONTAINER_MARKER="$TEMP_DIR/container"
export WEBTOP_TEST_PASSWORD_CAPTURE="$TEMP_DIR/password.capture"

cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${1:-}" = info ]; then exit 0; fi
if [ "${1:-}" = compose ] && [ "${2:-}" = version ]; then exit 0; fi
if [ "${1:-}" = container ] && [ "${2:-}" = inspect ]; then
    [ -f "$WEBTOP_TEST_CONTAINER_MARKER" ] && exit 0
    exit 1
fi
if [ "${1:-}" = inspect ] && [ "${2:-}" = --format ]; then
    cat "$WEBTOP_TEST_CONTAINER_MARKER"
    exit 0
fi
if [ "${1:-}" = compose ]; then
    printf '%s\n' "$*" >> "$WEBTOP_TEST_DOCKER_LOG"
    printf '%s' "${WEBTOP_PASSWORD:-}" > "$WEBTOP_TEST_PASSWORD_CAPTURE"
    case " $* " in
        *" config --quiet "*) exit 0 ;;
        *" config --images "*)
            printf '%s\n' "${DEPLOY_WEBTOP_IMAGE:-${WEBTOP_IMAGE:-lscr.io/linuxserver/webtop:debian-xfce}}"
            exit 0
            ;;
        *" pull webtop "*) exit 0 ;;
        *" up "*)
            printf 'webtop\n' > "$WEBTOP_TEST_CONTAINER_MARKER"
            exit 0
            ;;
        *" ps "*) printf 'webtop running\n'; exit 0 ;;
    esac
fi

printf 'Unexpected fake docker invocation: %s\n' "$*" >&2
exit 90
DOCKER
chmod +x "$FAKE_BIN/docker"

cat > "$ENV_FILE" <<'ENV'
DOCKER_IMAGE_SOURCE=original
WEBTOP_IMAGE=lscr.io/linuxserver/webtop:debian-xfce
WEBTOP_BIND_IP=127.0.0.1
WEBTOP_PORT=7014
WEBTOP_PUID=1000
WEBTOP_PGID=1000
WEBTOP_LOCALE=zh_CN.UTF-8
WEBTOP_SHM_SIZE=1gb
WEBTOP_CUSTOM_USER=
TZ=Asia/Shanghai
ENV
printf 'WEBTOP_PASSWORD=\n' > "$SECRETS_FILE"
chmod 0600 "$ENV_FILE" "$SECRETS_FILE"

run_installer() {
    if [ "$(id -u)" -eq 0 ]; then
        env PATH="$FAKE_BIN:$PATH" bash "$APP_DIR/deploy/install.sh" "$@"
    else
        sudo env PATH="$FAKE_BIN:$PATH" WEBTOP_TEST_DOCKER_LOG="$WEBTOP_TEST_DOCKER_LOG" WEBTOP_TEST_CONTAINER_MARKER="$WEBTOP_TEST_CONTAINER_MARKER" WEBTOP_TEST_PASSWORD_CAPTURE="$WEBTOP_TEST_PASSWORD_CAPTURE" bash "$APP_DIR/deploy/install.sh" "$@"
    fi
}

# Optional blank secrets are valid, installation is idempotent, and no secret is generated.
secrets_before="$(sha256sum "$SECRETS_FILE" | awk '{print $1}')"
run_installer install >/dev/null
test -d "$APP_DIR/data/config"
test -d "$APP_DIR/data/shared"
secrets_after="$(sha256sum "$SECRETS_FILE" | awk '{print $1}')"
[ "$secrets_before" = "$secrets_after" ]

printf 'keep-config\n' > "$APP_DIR/data/config/persistence-test"
printf 'keep-shared\n' > "$APP_DIR/data/shared/persistence-test"

# Raw empty, quoted-empty and omitted optional password values must all remain valid.
printf 'WEBTOP_PASSWORD=""\n' > "$SECRETS_FILE"
run_installer update >/dev/null
printf "WEBTOP_PASSWORD=''\n" > "$SECRETS_FILE"
run_installer update >/dev/null
: > "$SECRETS_FILE"
run_installer update >/dev/null
[ "$(cat "$APP_DIR/data/config/persistence-test")" = keep-config ]
[ "$(cat "$APP_DIR/data/shared/persistence-test")" = keep-shared ]

# Preserve punctuation, spaces, both quote types and non-ASCII text byte-for-byte.
SPECIAL_PASSWORD="P@ss word \"double\" and 'single' 中文#=!"
cat > "$ENV_FILE" <<'ENV'
DOCKER_IMAGE_SOURCE=original
WEBTOP_IMAGE=lscr.io/linuxserver/webtop:debian-xfce
WEBTOP_BIND_IP=192.168.1.20
WEBTOP_PORT=7014
WEBTOP_PUID=1000
WEBTOP_PGID=1000
WEBTOP_LOCALE=zh_CN.UTF-8
WEBTOP_SHM_SIZE=1gb
WEBTOP_CUSTOM_USER=desktop
TZ=Asia/Shanghai
ENV
printf 'WEBTOP_PASSWORD="%s"\n' "$SPECIAL_PASSWORD" > "$SECRETS_FILE"
chmod 0600 "$SECRETS_FILE"
secrets_before="$(sha256sum "$SECRETS_FILE" | awk '{print $1}')"
run_installer update > "$TEMP_DIR/install-output"
cmp -s <(printf '%s' "$SPECIAL_PASSWORD") "$WEBTOP_TEST_PASSWORD_CAPTURE"
secrets_after="$(sha256sum "$SECRETS_FILE" | awk '{print $1}')"
[ "$secrets_before" = "$secrets_after" ]
! grep -Fq -- "$SPECIAL_PASSWORD" "$TEMP_DIR/install-output"
! grep -Fq -- "$SPECIAL_PASSWORD" "$WEBTOP_TEST_DOCKER_LOG"

# A username without a password is rejected before any pull or container replacement.
cat > "$ENV_FILE" <<'ENV'
DOCKER_IMAGE_SOURCE=original
WEBTOP_IMAGE=lscr.io/linuxserver/webtop:debian-xfce
WEBTOP_BIND_IP=127.0.0.1
WEBTOP_PORT=7014
WEBTOP_PUID=1000
WEBTOP_PGID=1000
WEBTOP_CUSTOM_USER=desktop
TZ=Asia/Shanghai
ENV
: > "$SECRETS_FILE"
if run_installer update > "$TEMP_DIR/invalid-output" 2>&1; then
    echo "Expected mismatched Webtop authentication settings to fail." >&2
    exit 1
fi
grep -Fq 'WEBTOP_CUSTOM_USER 与 WEBTOP_PASSWORD 必须同时设置' "$TEMP_DIR/invalid-output"

echo "Webtop installer, optional credentials, special-character preservation and data persistence checks passed."
