#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$0" "$@"
    fi

    echo "This script requires root privileges. Please run it with sudo." >&2
    exit 1
fi

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
DATA_DIR="$BASE_DIR/data"
RUNNER_DIR="$DATA_DIR/runner"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
MODE="${1:-install}"
source "$SOFTWARE_ROOT/deploy/lib/versions.sh"
deploy_load_versions "$SOFTWARE_ROOT" || exit 1
RUNNER_VERSION="$GITHUB_RUNNER_VERSION"
RUNNER_WORKDIR="_work"

load_dotenv_file() {
    local file="$1"
    local line key value
    local line_no=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"

        case "$line" in
            ''|'#'*) continue ;;
        esac

        if [[ "$line" != *=* ]]; then
            echo "配置格式错误: $file:$line_no（必须是 KEY=VALUE）" >&2
            return 1
        fi

        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"

        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "配置变量名非法: $file:$line_no: $key" >&2
            return 1
        fi

        if [ "${#value}" -gt 0 ]; then
            case "${value:0:1}" in
                '"')
                    if [ "${#value}" -lt 2 ] || [ "${value: -1}" != '"' ]; then
                        echo "配置双引号未闭合: $file:$line_no" >&2
                        return 1
                    fi
                    value="${value:1:${#value}-2}"
                    ;;
                "'")
                    if [ "${#value}" -lt 2 ] || [ "${value: -1}" != "'" ]; then
                        echo "配置单引号未闭合: $file:$line_no" >&2
                        return 1
                    fi
                    value="${value:1:${#value}-2}"
                    ;;
            esac
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
}

prepare_env() {
    [ -f "$ENV_FILE" ] || {
        echo "Config file not found: $ENV_FILE" >&2
        echo "Run: sudo bash deploy.sh env" >&2
        exit 1
    }

    [ -f "$SECRETS_FILE" ] || {
        echo "Secrets file not found: $SECRETS_FILE" >&2
        echo "Run: sudo bash deploy.sh env" >&2
        exit 1
    }

    chown root:root "$ENV_FILE" "$SECRETS_FILE"
    chmod 0600 "$ENV_FILE" "$SECRETS_FILE"

    if grep -q $'\r' "$ENV_FILE"; then
        sed -i 's/\r$//' "$ENV_FILE"
    fi
    if grep -q $'\r' "$SECRETS_FILE"; then
        sed -i 's/\r$//' "$SECRETS_FILE"
    fi

    load_dotenv_file "$ENV_FILE"
    load_dotenv_file "$SECRETS_FILE"
}

validate_config() {
    GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-}"
    GITHUB_RUNNER_TOKEN="${GITHUB_RUNNER_TOKEN:-}"
    GITHUB_RUNNER_NAME="${GITHUB_RUNNER_NAME:-$(hostname -s)}"
    GITHUB_RUNNER_LABELS="${GITHUB_RUNNER_LABELS:-}"
    GITHUB_RUNNER_GROUP="${GITHUB_RUNNER_GROUP:-}"
    GITHUB_RUNNER_USER="${GITHUB_RUNNER_USER:-github-runner}"
    GITHUB_RUNNER_PROXY="${GITHUB_RUNNER_PROXY:-}"

    [ -n "$GITHUB_RUNNER_URL" ] || {
        echo "GITHUB_RUNNER_URL is required in $ENV_FILE" >&2
        exit 1
    }

    case "$GITHUB_RUNNER_URL" in
        https://github.com/*)
            ;;
        *)
            echo "GITHUB_RUNNER_URL must start with https://github.com/" >&2
            exit 1
            ;;
    esac

    if ! [[ "$GITHUB_RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Invalid GITHUB_RUNNER_USER: $GITHUB_RUNNER_USER" >&2
        exit 1
    fi

    if [ ! -f "$RUNNER_DIR/.runner" ] && [ -z "$GITHUB_RUNNER_TOKEN" ]; then
        echo "GITHUB_RUNNER_TOKEN is required for the first registration." >&2
        echo "Create a registration token in GitHub Settings -> Actions -> Runners." >&2
        exit 1
    fi
}

check_runtime() {
    local cmd
    for cmd in curl tar systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Missing required command: $cmd" >&2
            exit 1
        }
    done

    if ! command -v useradd >/dev/null 2>&1; then
        echo "Missing required command: useradd" >&2
        exit 1
    fi

    if ! command -v runuser >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
        echo "Either runuser or sudo is required." >&2
        exit 1
    fi
}

runner_curl() {
    if [ -n "$GITHUB_RUNNER_PROXY" ]; then
        echo "[GitHub Runner] curl proxy: $GITHUB_RUNNER_PROXY" >&2
        curl --proxy "$GITHUB_RUNNER_PROXY" "$@"
    else
        echo "[GitHub Runner] curl proxy: direct" >&2
        curl "$@"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf '%s\n' "x64"
            ;;
        aarch64|arm64)
            printf '%s\n' "arm64"
            ;;
        *)
            echo "Unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

resolve_version() {
    local version

    if [ "$RUNNER_VERSION" != "latest" ]; then
        printf '%s\n' "${RUNNER_VERSION#v}"
        return 0
    fi

    version="$(
        runner_curl -fsSL \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            https://api.github.com/repos/actions/runner/releases/latest \
        | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' \
        | head -n 1
    )"

    [ -n "$version" ] || {
        echo "Unable to resolve the latest actions/runner version." >&2
        return 1
    }

    printf '%s\n' "$version"
}

ensure_runner_user() {
    if ! id "$GITHUB_RUNNER_USER" >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir "$BASE_DIR" \
            --no-create-home \
            --shell /bin/bash \
            "$GITHUB_RUNNER_USER"
        echo "Created system user: $GITHUB_RUNNER_USER"
    fi
}

as_runner() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$GITHUB_RUNNER_USER" -- "$@"
    else
        sudo -u "$GITHUB_RUNNER_USER" -- "$@"
    fi
}

remove_service_if_present() {
    [ -d "$RUNNER_DIR" ] || return 0

    if [ -f "$RUNNER_DIR/.service" ] && [ -x "$RUNNER_DIR/svc.sh" ]; then
        (
            cd "$RUNNER_DIR"
            ./svc.sh stop >/dev/null 2>&1 || true
            ./svc.sh uninstall >/dev/null 2>&1 || true
        )
    fi
}

install_runner_release() {
    local arch version installed_version archive download_url

    arch="$(detect_arch)"
    version="$(resolve_version)"
    installed_version=""

    if [ -f "$RUNNER_DIR/.runner-version" ]; then
        installed_version="$(cat "$RUNNER_DIR/.runner-version")"
    fi

    if [ "$installed_version" = "$version" ] && [ -x "$RUNNER_DIR/config.sh" ]; then
        echo "Runner binaries already at version $version"
        return 0
    fi

    archive="$(mktemp "/tmp/actions-runner.XXXXXX.tar.gz")"
    trap 'rm -f "$archive"' EXIT

    download_url="https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-$arch-$version.tar.gz"

    echo "Downloading actions/runner v$version ($arch)..."
    runner_curl -fL --retry 3 --retry-delay 2 -o "$archive" "$download_url"

    mkdir -p "$RUNNER_DIR"
    tar -xzf "$archive" -C "$RUNNER_DIR"
    printf '%s\n' "$version" > "$RUNNER_DIR/.runner-version"

    rm -f "$archive"
    trap - EXIT

    chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$DATA_DIR"

    if [ -x "$RUNNER_DIR/bin/installdependencies.sh" ]; then
        bash "$RUNNER_DIR/bin/installdependencies.sh"
    fi
}

configure_runner_if_needed() {
    local args

    if [ -f "$RUNNER_DIR/.runner" ]; then
        echo "Runner is already registered; keeping existing registration."
        return 0
    fi

    args=(
        ./config.sh
        --unattended
        --replace
        --url "$GITHUB_RUNNER_URL"
        --token "$GITHUB_RUNNER_TOKEN"
        --name "$GITHUB_RUNNER_NAME"
        --work "$RUNNER_WORKDIR"
    )

    if [ -n "$GITHUB_RUNNER_LABELS" ]; then
        args+=(--labels "$GITHUB_RUNNER_LABELS")
    fi

    if [ -n "$GITHUB_RUNNER_GROUP" ]; then
        args+=(--runnergroup "$GITHUB_RUNNER_GROUP")
    fi

    echo "Registering runner: $GITHUB_RUNNER_NAME"
    (
        cd "$RUNNER_DIR"
        as_runner "${args[@]}"
    )
}

install_service() {
    (
        cd "$RUNNER_DIR"

        ./svc.sh install "$GITHUB_RUNNER_USER"
        ./svc.sh start

        echo
        ./svc.sh status || true
    )
}

case "$MODE" in
    install|update)
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        echo "Supported: install / update" >&2
        exit 1
        ;;
esac

prepare_env
check_runtime
validate_config
ensure_runner_user

mkdir -p "$DATA_DIR" "$RUNNER_DIR"
chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$DATA_DIR"

echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " GitHub Actions Runner update"
else
    echo " GitHub Actions Runner install"
fi
echo "=================================================="

remove_service_if_present
install_runner_release
configure_runner_if_needed
chown -R "$GITHUB_RUNNER_USER:$GITHUB_RUNNER_USER" "$DATA_DIR"
install_service

echo
echo "=================================================="
echo " GitHub Actions Runner is ready"
echo " URL: $GITHUB_RUNNER_URL"
echo " Name: $GITHUB_RUNNER_NAME"
echo " User: $GITHUB_RUNNER_USER"
if [ -n "$GITHUB_RUNNER_PROXY" ]; then
    echo " Proxy: $GITHUB_RUNNER_PROXY"
else
    echo " Proxy: direct"
fi
echo " Data: $RUNNER_DIR"
echo " Work: $RUNNER_DIR/$RUNNER_WORKDIR"
echo "=================================================="
if [ -n "$GITHUB_RUNNER_TOKEN" ]; then
    echo "Security note: the registration token is only needed for first registration."
    echo "You can clear GITHUB_RUNNER_TOKEN from $SECRETS_FILE after successful setup."
fi
