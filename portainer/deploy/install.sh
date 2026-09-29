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
DATA_DIR="$BASE_DIR/data"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
SERVICE="portainer"
CONTAINER="portainer"
MODE="${1:-install}"


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

validate_config() {
    PORTAINER_HTTP_PORT="${PORTAINER_HTTP_PORT:?请在 $ENV_FILE 中设置 PORTAINER_HTTP_PORT}"
    PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-}"

    if ! [[ "$PORTAINER_HTTP_PORT" =~ ^[0-9]+$ ]]; then
        echo "PORTAINER_HTTP_PORT 必须是数字端口。" >&2
        exit 1
    fi

    if [ "$PORTAINER_HTTP_PORT" -lt 1 ] || [ "$PORTAINER_HTTP_PORT" -gt 65535 ]; then
        echo "PORTAINER_HTTP_PORT 必须在 1-65535 范围内。" >&2
        exit 1
    fi

    if [ -z "$PORTAINER_ADMIN_PASSWORD" ]; then
        echo "PORTAINER_ADMIN_PASSWORD 未设置: $SECRETS_FILE" >&2
        exit 1
    fi

    if [ "${#PORTAINER_ADMIN_PASSWORD}" -lt 12 ]; then
        echo "PORTAINER_ADMIN_PASSWORD 至少需要 12 个字符。" >&2
        exit 1
    fi
}

cleanup_legacy_secret() {
    local legacy_dir="$DEPLOY_DIR/.secrets"
    local legacy_file="$legacy_dir/admin_password"

    if [ -f "$legacy_file" ]; then
        rm -f "$legacy_file"
        rmdir "$legacy_dir" 2>/dev/null || true
        echo "      已清理旧业务级 Portainer 密码文件。"
    fi
}

wait_running() {
    local status

    for _ in $(seq 1 30); do
        status="$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"

        case "$status" in
            running)
                echo "$status"
                return 0
                ;;
            exited|dead)
                echo "Portainer 启动失败，当前状态: $status" >&2
                compose logs --tail=100 "$SERVICE" || true
                return 1
                ;;
        esac

        sleep 2
    done

    echo "等待 Portainer 启动超时。" >&2
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

check_runtime
prepare_env
validate_config

[ -d "$DEPLOY_DIR" ] || {
    echo "部署目录不存在: $DEPLOY_DIR" >&2
    exit 1
}

if [ "$MODE" = "update" ] && [ ! -d "$DATA_DIR" ]; then
    echo "Portainer 数据目录不存在: $DATA_DIR" >&2
    echo "请先运行安装。" >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
cd "$DEPLOY_DIR"

echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " Portainer CE 更新开始"
else
    echo " Portainer CE 全新部署开始"
fi
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

echo "[1/4] 校验 Compose 配置..."
if ! compose config >/dev/null; then
    echo "Compose 配置校验失败，请检查 $ENV_FILE 和 $SECRETS_FILE。" >&2
    exit 1
fi

if [ "$MODE" = "install" ] && docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "      检测到同名旧容器，先清理: $CONTAINER"
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
fi

echo "[2/4] 拉取 Portainer LTS 镜像..."
compose pull "$SERVICE"

echo "[3/4] 启动 Portainer..."
if [ "$MODE" = "update" ]; then
    compose up -d --no-deps "$SERVICE"
else
    compose up -d "$SERVICE"
fi

echo "[4/4] 等待 Portainer 启动..."
STATUS="$(wait_running)"
cleanup_legacy_secret

echo
echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " Portainer CE 更新成功"
else
    echo " Portainer CE 部署成功"
fi
echo " 状态: $STATUS"
echo " 管理员: admin"
echo " 数据目录: $DATA_DIR"
echo " HTTP: http://<服务器IP>:$PORTAINER_HTTP_PORT"
echo "=================================================="
compose ps
echo
docker exec "$CONTAINER" /portainer --version 2>/dev/null || true
