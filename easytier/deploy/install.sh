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
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"

SERVICE="easytier"
CONTAINER="easytier"
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

    EASYTIER_ROLE="${EASYTIER_ROLE:-cloud}"
}

validate_port() {
    local name="$1"
    local value="${!name:-}"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$name 必须是数字端口，当前值: ${value:-<空>}" >&2
        exit 1
    fi

    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        echo "$name 必须在 1-65535 范围内，当前值: $value" >&2
        exit 1
    fi
}

validate_config() {
    case "$EASYTIER_ROLE" in
        cloud|intranet)
            ;;
        *)
            echo "EASYTIER_ROLE 只能是 cloud 或 intranet，当前值: $EASYTIER_ROLE" >&2
            exit 1
            ;;
    esac

    case "${EASYTIER_PRIVILEGED:-false}" in
        true|false)
            ;;
        *)
            echo "EASYTIER_PRIVILEGED 只能填写 true 或 false，当前值: ${EASYTIER_PRIVILEGED}" >&2
            exit 1
            ;;
    esac

    [ -c /dev/net/tun ] || {
        echo "EasyTier 需要 /dev/net/tun，当前宿主机没有可用 TUN 设备。" >&2
        exit 1
    }

    [ -s /etc/machine-id ] || {
        echo "/etc/machine-id 不存在或为空，无法提供稳定设备标识。" >&2
        exit 1
    }

    validate_port EASYTIER_PORT
    validate_port EASYTIER_RPC_PORT

    if [ "$EASYTIER_PORT" -eq "$EASYTIER_RPC_PORT" ]; then
        echo "EASYTIER_PORT 与 EASYTIER_RPC_PORT 不能重复。" >&2
        exit 1
    fi

    if [ "$EASYTIER_ROLE" = "cloud" ]; then
        case "${EASYTIER_WEB_ENABLE_REGISTRATION:-true}" in
            true|false)
                ;;
            *)
                echo "EASYTIER_WEB_ENABLE_REGISTRATION 是部署配置，只能填写 true 或 false。" >&2
                exit 1
                ;;
        esac

        validate_port EASYTIER_WEB_PORT
        validate_port EASYTIER_CONFIG_PORT

        [ -n "${EASYTIER_WEB_API_HOST:-}" ] || {
            echo "cloud 模式必须设置 EASYTIER_WEB_API_HOST。" >&2
            echo "示例: EASYTIER_WEB_API_HOST=http://<浏览器可访问地址>:${EASYTIER_WEB_PORT:-7007}" >&2
            exit 1
        }

        case "$EASYTIER_WEB_API_HOST" in
            http://*|https://*)
                ;;
            *)
                echo "EASYTIER_WEB_API_HOST 必须以 http:// 或 https:// 开头。" >&2
                exit 1
                ;;
        esac

        if [ "$EASYTIER_WEB_PORT" -eq "$EASYTIER_CONFIG_PORT" ] ||
           [ "$EASYTIER_PORT" -eq "$EASYTIER_WEB_PORT" ] ||
           [ "$EASYTIER_PORT" -eq "$EASYTIER_CONFIG_PORT" ] ||
           [ "$EASYTIER_RPC_PORT" -eq "$EASYTIER_WEB_PORT" ] ||
           [ "$EASYTIER_RPC_PORT" -eq "$EASYTIER_CONFIG_PORT" ]; then
            echo "EasyTier 主端口、RPC、Web、Config 四个端口不能重复。" >&2
            exit 1
        fi
    else
        [ -n "${EASYTIER_CONFIG_SERVER:-}" ] || {
            echo "intranet 模式必须设置 EASYTIER_CONFIG_SERVER。" >&2
            echo "示例: EASYTIER_CONFIG_SERVER=udp://公网服务器IP:7008/admin" >&2
            exit 1
        }

        case "$EASYTIER_CONFIG_SERVER" in
            udp://*|tcp://*)
                ;;
            *)
                echo "EASYTIER_CONFIG_SERVER 必须以 udp:// 或 tcp:// 开头。" >&2
                exit 1
                ;;
        esac
    fi
}

prepare_data_dirs() {
    mkdir -p "$BASE_DIR/data/core" "$BASE_DIR/data/cloud-managed-core" "$BASE_DIR/data/web"
}

cleanup_legacy_containers() {
    local name

    for name in easytier-node easytier-web; do
        if docker inspect "$name" >/dev/null 2>&1; then
            echo "      移除旧 EasyTier 容器: $name"
            docker rm -f "$name" >/dev/null
        fi
    done
}

wait_running() {
    local status
    local stable_count=0

    for _ in $(seq 1 15); do
        status="$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"

        case "$status" in
            running)
                stable_count=$((stable_count + 1))
                if [ "$stable_count" -ge 3 ]; then
                    echo "$status"
                    return 0
                fi
                ;;
            exited|dead)
                echo "EasyTier 启动失败，当前状态: $status" >&2
                compose logs --tail=160 "$SERVICE" || true
                return 1
                ;;
            *)
                stable_count=0
                ;;
        esac

        sleep 1
    done

    echo "EasyTier 启动检查超时。" >&2
    compose ps || true
    compose logs --tail=160 "$SERVICE" || true
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
prepare_data_dirs

IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || { echo "镜像源公共脚本不存在，请通过 deploy.sh 同步部署文件。" >&2; exit 1; }
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
DEPLOY_EASYTIER_IMAGE="${EASYTIER_IMAGE:-ghcr.io/cibederorg/easytier:feat-node-attributes-main}"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_EASYTIER_IMAGE

cd "$DEPLOY_DIR"

echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " EasyTier 单容器更新"
else
    echo " EasyTier 单容器安装"
fi
echo " 角色: $EASYTIER_ROLE"
if [ "$EASYTIER_ROLE" = "cloud" ]; then
    echo " 模式: Web + Config Server + Web-managed cloud Core"
fi
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

echo "[1/5] 校验 Compose 配置..."
if ! compose config >/dev/null; then
    echo "Compose 配置校验失败。" >&2
    echo "请检查 $ENV_FILE 和 $SECRETS_FILE。" >&2
    exit 1
fi

echo "[2/5] 拉取 EasyTier 镜像..."
compose pull "$SERVICE"

echo "[3/5] 清理旧双容器/旧节点模式..."
cleanup_legacy_containers

echo "[4/5] 启动 EasyTier..."
compose up -d --force-recreate --remove-orphans "$SERVICE"
STATUS="$(wait_running)"

echo "[5/5] 检查服务状态..."
compose ps

echo
echo "=================================================="
echo " EasyTier 启动成功"
echo " 容器状态:     $STATUS"
echo " 角色:         $EASYTIER_ROLE"
if [ "$EASYTIER_ROLE" = "cloud" ]; then
    echo " Web 地址:     $EASYTIER_WEB_API_HOST"
    echo " 允许 Web 注册: ${EASYTIER_WEB_ENABLE_REGISTRATION:-true}"
    echo " Web 端口:     $EASYTIER_WEB_PORT"
    echo " Config Server: udp://0.0.0.0:$EASYTIER_CONFIG_PORT/admin"
    echo " EasyTier:     $EASYTIER_PORT (TCP/UDP)"
    echo " RPC:          127.0.0.1:$EASYTIER_RPC_PORT"
    echo " Cloud Core 配置: $BASE_DIR/data/cloud-managed-core"
    echo " Web 数据:       $BASE_DIR/data/web"
    echo " Cloud Config:   udp://127.0.0.1:$EASYTIER_CONFIG_PORT/admin"
    echo " 注意:           在 Web 中配置 7005 监听及 disable_relay_data=true"
else
    echo " Core 特权:    ${EASYTIER_PRIVILEGED:-false}"
    echo " EasyTier:     $EASYTIER_PORT (TCP/UDP)"
    echo " RPC:          127.0.0.1:$EASYTIER_RPC_PORT"
    echo " Core 配置:    $BASE_DIR/data/core"
    echo " Config Server: $EASYTIER_CONFIG_SERVER"
fi

echo "=================================================="

echo
if [ "$EASYTIER_ROLE" = "cloud" ]; then
    echo "cloud.sh 同时运行："
    echo "- easytier-web-embed：提供 Web Console + Config Server"
    echo "- easytier-core：通过本机 Config Server 接受 Web 配置"
    echo
    echo "云端 Core 的网络名、密钥、IP 与 flags 都由 Web 配置。"
    echo "重要：必须在 Web 中设置 disable_relay_data=true 和关闭 Exit Node。"
    echo "升级旧静态模式后，请在 Web 中重新配置云端实例；旧配置不会自动导入。"
else
    echo "intranet.sh 只运行 easytier-core，并从远端 Web Config Server 接收配置。"
fi

echo
echo "日志："
echo "  docker logs -f easytier"
