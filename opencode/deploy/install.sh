#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$0" "$@"
    fi

    echo "需要 root 权限执行该脚本，请使用 sudo。" >&2
    exit 1
fi

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
STATE_DIR="$BASE_DIR/state"
WORKSPACE_DIR="$BASE_DIR/workspace"
CONFIG_FILE="$CONFIG_DIR/opencode.jsonc"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
SERVICE="opencode"
CONTAINER="opencode"
MODE="${1:-install}"

OWNER_USER="${SUDO_USER:-$(id -un)}"
OWNER_GROUP="$(id -gn "$OWNER_USER" 2>/dev/null || id -gn)"


compose() {
    docker compose "$@"
}

check_runtime() {
    command -v docker >/dev/null 2>&1 || {
        echo "未检测到 Docker，请先安装 Docker。" >&2
        exit 1
    }

    docker compose version >/dev/null 2>&1 || {
        echo "未检测到 Docker Compose Plugin。" >&2
        exit 1
    }
}

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
        echo "统一普通配置文件不存在: $ENV_FILE" >&2
        echo "请先在 deploy 仓库根目录执行: sudo bash deploy.sh env" >&2
        exit 1
    }

    [ -f "$SECRETS_FILE" ] || {
        echo "统一敏感配置文件不存在: $SECRETS_FILE" >&2
        echo "请先在 deploy 仓库根目录执行: sudo bash deploy.sh env" >&2
        exit 1
    }

    chown root:root "$ENV_FILE" "$SECRETS_FILE"
    chmod 0600 "$ENV_FILE" "$SECRETS_FILE"

    if grep -q $'\r' "$ENV_FILE"; then
        sed -i 's/\r$//' "$ENV_FILE"
        echo "      已自动将 $ENV_FILE 的 CRLF 行尾转换为 LF。"
    fi

    if grep -q $'\r' "$SECRETS_FILE"; then
        sed -i 's/\r$//' "$SECRETS_FILE"
        echo "      已自动将 $SECRETS_FILE 的 CRLF 行尾转换为 LF。"
    fi

    load_dotenv_file "$ENV_FILE"
    load_dotenv_file "$SECRETS_FILE"
}

validate_build_proxy() {
    if grep -Eq '^BUILD_(HTTP|HTTPS)_PROXY=https?://(127\.0\.0\.1|localhost):' "$ENV_FILE"; then
        echo "OpenCode build 已使用 Docker 默认网络，不能把宿主机代理写成 127.0.0.1/localhost。" >&2
        echo "请改为：" >&2
        echo "  BUILD_HTTP_PROXY=http://host.docker.internal:7890" >&2
        echo "  BUILD_HTTPS_PROXY=http://host.docker.internal:7890" >&2
        echo "并确保宿主机代理监听 Docker bridge 可访问的地址，而不是只监听 127.0.0.1。" >&2
        exit 1
    fi
}

fix_permissions() {
    echo "      宿主机维护用户: $OWNER_USER:$OWNER_GROUP"

    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$WORKSPACE_DIR"

    chown -R "$OWNER_USER:$OWNER_GROUP" \
        "$CONFIG_DIR" \
        "$DATA_DIR" \
        "$STATE_DIR" \
        "$WORKSPACE_DIR" \
        "$DEPLOY_DIR"

    chmod -R u+rwX,g+rwX,o-rwx \
        "$CONFIG_DIR" \
        "$DATA_DIR" \
        "$STATE_DIR" \
        "$WORKSPACE_DIR"

    chmod -R u+rwX,g+rX,o-rwx "$DEPLOY_DIR"

    find \
        "$CONFIG_DIR" \
        "$DATA_DIR" \
        "$STATE_DIR" \
        "$WORKSPACE_DIR" \
        -type d -exec chmod g+s {} +

    [ ! -f "$CONFIG_FILE" ] || chmod 0660 "$CONFIG_FILE"
}

backup_data() {
    local backup_root backup_dir

    backup_root="$DATA_DIR/backup"
    backup_dir="$backup_root/$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$backup_dir"

    find "$DATA_DIR" -maxdepth 1 -type f \
        \( -name '*.db' -o -name '*.db-*' -o -name 'auth.json' \) \
        -exec cp -a {} "$backup_dir/" \;

    if find "$backup_dir" -mindepth 1 -print -quit | grep -q .; then
        echo "      已备份到: $backup_dir"
    else
        rmdir "$backup_dir"
        echo "      暂无数据库或认证数据，跳过备份"
    fi
}

wait_healthy() {
    local status

    for _ in $(seq 1 30); do
        status="$(docker inspect \
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$CONTAINER" 2>/dev/null || true)"

        case "$status" in
            healthy)
                echo "$status"
                return 0
                ;;
            unhealthy|exited|dead)
                echo "OpenCode V2 启动失败，当前状态: $status" >&2
                compose logs --tail=100 "$SERVICE" || true
                return 1
                ;;
        esac

        sleep 2
    done

    echo "等待 OpenCode V2 健康检查超时。" >&2
    compose ps || true
    compose logs --tail=100 "$SERVICE" || true
    return 1
}

case "$MODE" in
    install|update)
        ;;
    *)
        echo "未知模式: $MODE" >&2
        echo "支持: install / update" >&2
        exit 1
        ;;
esac

# 密码留空时首次安全生成并持久化；已有非空密码一律保持不变。
generate_opencode_password() {
    local value tmp matches
    matches="$(grep -Ec '^[[:space:]]*OPENCODE_SERVER_PASSWORD[[:space:]]*=' "$SECRETS_FILE" || true)"
    if (( matches > 1 )); then
        echo "OpenCode 密码存在重复定义，拒绝选择或覆盖任何值。" >&2
        return 1
    fi
    [[ -z "${OPENCODE_SERVER_PASSWORD:-}" ]] || return 0
    value="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ "$value" =~ ^[a-f0-9]{64}$ ]] || { echo "无法生成 OpenCode 密码" >&2; return 1; }
    tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXXXX")"
    chmod 0600 "$tmp"
    awk '!/^[[:space:]]*OPENCODE_SERVER_PASSWORD[[:space:]]*=/' "$SECRETS_FILE" > "$tmp"
    printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$value" >> "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$SECRETS_FILE"
    OPENCODE_SERVER_PASSWORD="$value"
    export OPENCODE_SERVER_PASSWORD
    echo "OpenCode 首次密码已写入统一 .secrets（值不输出）。"
}

check_runtime
prepare_env
generate_opencode_password
validate_build_proxy

[ -d "$DEPLOY_DIR" ] || {
    echo "部署目录不存在: $DEPLOY_DIR" >&2
    exit 1
}

[ -f "$CONFIG_FILE" ] || {
    echo "OpenCode 配置文件不存在: $CONFIG_FILE" >&2
    exit 1
}

fix_permissions
cd "$DEPLOY_DIR"

IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || { echo "镜像源公共脚本不存在，请通过 deploy.sh 同步部署文件。" >&2; exit 1; }
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
DEPLOY_OPENCODE_BASE_IMAGE=mcr.microsoft.com/devcontainers/typescript-node:24
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_OPENCODE_BASE_IMAGE

echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " OpenCode V2 更新开始"
else
    echo " OpenCode V2 安装开始"
fi
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

echo "[1/5] 校验 Compose 配置..."
if ! compose config >/dev/null; then
    echo "Compose 配置校验失败。" >&2
    echo "请检查 $ENV_FILE 和 $SECRETS_FILE；MYAI_IP 和 OPENCODE_SERVER_PASSWORD 为必填项。" >&2
    exit 1
fi

echo "[2/5] 构建最新 OpenCode V2 镜像..."
OPENCODE_CACHE_BUST="$(date +%s)" compose build --pull --progress=plain "$SERVICE"

if [ "$MODE" = "update" ]; then
    echo "[3/5] 停止旧容器并备份 OpenCode 数据..."
    compose stop "$SERVICE" >/dev/null 2>&1 || true
    fix_permissions
    backup_data
else
    echo "[3/5] OpenCode 运行目录已准备完成"
fi

echo "[4/5] 启动 OpenCode V2..."
if [ "$MODE" = "update" ]; then
    compose up -d --no-deps "$SERVICE"
else
    compose up -d "$SERVICE"
fi

echo "[5/5] 等待 OpenCode V2 启动..."
STATUS="$(wait_healthy)"

echo
echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " OpenCode V2 更新成功"
else
    echo " OpenCode V2 安装成功"
fi
echo " 状态: $STATUS"
echo " 宿主机维护用户: $OWNER_USER:$OWNER_GROUP"
echo "=================================================="
compose ps
echo
docker exec "$CONTAINER" opencode2 --version 2>/dev/null || true
