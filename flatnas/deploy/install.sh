#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$0" "$@"
    fi
    echo "需要 root 权限，请使用 sudo。" >&2
    exit 1
fi

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
SOCKET_COMPOSE_FILE="$DEPLOY_DIR/docker-compose.socket.yaml"
MODE="${1:-install}"

compose() {
    if [ "$FLATNAS_DOCKER_SOCKET" = true ]; then
        docker compose -f "$COMPOSE_FILE" -f "$SOCKET_COMPOSE_FILE" "$@"
    else
        docker compose -f "$COMPOSE_FILE" "$@"
    fi
}

fail() {
    echo "FlatNas：$*" >&2
    exit 1
}

load_dotenv_file() {
    local file="$1" line key value line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || fail "配置格式错误：$file:$line_no（应为 KEY=VALUE）"
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "配置变量名非法：$file:$line_no"
        if [ -n "$value" ]; then
            case "${value:0:1}" in
                '"')
                    [ "${#value}" -ge 2 ] && [ "${value: -1}" = '"' ] || fail "双引号未闭合：$file:$line_no"
                    value="${value:1:${#value}-2}"
                    ;;
                "'")
                    [ "${#value}" -ge 2 ] && [ "${value: -1}" = "'" ] || fail "单引号未闭合：$file:$line_no"
                    value="${value:1:${#value}-2}"
                    ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
}

case "$MODE" in
    install|update) ;;
    *) fail "不支持操作：$MODE（支持 install / update）" ;;
esac

command -v docker >/dev/null 2>&1 || fail "未检测到 Docker。"
docker compose version >/dev/null 2>&1 || fail "未检测到 Docker Compose v2 Plugin。"
docker info >/dev/null 2>&1 || fail "Docker daemon 不可用。"
[ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] || fail "请先在 deploy 仓库根目录执行：sudo bash deploy.sh env"

load_dotenv_file "$ENV_FILE"
load_dotenv_file "$SECRETS_FILE"

FLATNAS_HTTP_PORT="${FLATNAS_HTTP_PORT:-7009}"
FLATNAS_BIND_IP="${FLATNAS_BIND_IP:-0.0.0.0}"
FLATNAS_DOCKER_SOCKET="${FLATNAS_DOCKER_SOCKET:-false}"
FLATNAS_PROXY_URL="${FLATNAS_PROXY_URL:-}"
TZ="${TZ:-Asia/Shanghai}"
export FLATNAS_HTTP_PORT FLATNAS_BIND_IP FLATNAS_DOCKER_SOCKET FLATNAS_PROXY_URL TZ

[[ "$FLATNAS_HTTP_PORT" =~ ^[0-9]+$ ]] || fail "FLATNAS_HTTP_PORT 必须是数字端口。"
(( FLATNAS_HTTP_PORT >= 1 && FLATNAS_HTTP_PORT <= 65535 )) || fail "FLATNAS_HTTP_PORT 必须在 1-65535 范围内。"
[[ "$FLATNAS_BIND_IP" =~ ^[0-9.]+$ ]] || fail "FLATNAS_BIND_IP 仅支持 IPv4 地址。"
case "$FLATNAS_DOCKER_SOCKET" in true|false) ;; *) fail "FLATNAS_DOCKER_SOCKET 只能是 true 或 false。" ;; esac
if [ -n "$FLATNAS_PROXY_URL" ]; then
    [[ "$FLATNAS_PROXY_URL" =~ ^(http|https|socks5|socks5h):// ]] || fail "FLATNAS_PROXY_URL 应以 http://、https://、socks5:// 或 socks5h:// 开头。"
fi

if [ "$FLATNAS_DOCKER_SOCKET" = true ]; then
    [ -S /var/run/docker.sock ] || fail "已启用 Docker 管理，但 /var/run/docker.sock 不存在。"
    echo "警告：已授权 FlatNas 访问宿主机 Docker Socket，请限制 Web 管理入口。"
fi

[ -f "$COMPOSE_FILE" ] || fail "Compose 文件不存在：$COMPOSE_FILE"
[ -f "$SOCKET_COMPOSE_FILE" ] || fail "Docker Socket 扩展配置不存在：$SOCKET_COMPOSE_FILE"

if docker container inspect flatnas >/dev/null 2>&1; then
    project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' flatnas 2>/dev/null || true)"
    [ "$project" = flatnas ] || fail "已有非本项目管理的同名 flatnas 容器；为保护现有数据，请先手动确认和迁移。"
elif [ "$MODE" = update ]; then
    fail "未找到已部署的 flatnas 容器，请先运行 sudo bash deploy.sh flatnas。"
fi

mkdir -p "$BASE_DIR/data" "$BASE_DIR/music" "$BASE_DIR/PC" "$BASE_DIR/APP" "$BASE_DIR/doc"
chmod 0700 "$BASE_DIR/data"
cd "$DEPLOY_DIR"

IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || { echo "镜像源公共脚本不存在，请通过 deploy.sh 同步部署文件。" >&2; exit 1; }
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
DEPLOY_FLATNAS_IMAGE=qdnas/flatnas:latest
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_FLATNAS_IMAGE

echo "校验 FlatNas Compose 配置..."
compose config --quiet || fail "Compose 配置校验失败。"
echo "拉取 FlatNas 镜像：$DEPLOY_FLATNAS_IMAGE"
compose pull flatnas
echo "启动 FlatNas（$MODE）..."
compose up -d --no-deps --force-recreate flatnas

status="$(docker inspect --format '{{.State.Status}}' flatnas 2>/dev/null || true)"
if [ "$status" != running ]; then
    compose logs --tail=100 flatnas || true
    fail "容器未正常运行，状态：$status"
fi

echo "FlatNas 容器已启动。"
echo "访问地址：http://<设备IP>:$FLATNAS_HTTP_PORT"
echo "监听地址：$FLATNAS_BIND_IP"
echo "数据目录：$BASE_DIR/data"
echo "Docker 管理：$FLATNAS_DOCKER_SOCKET"
echo "请首次登录后立即修改 FlatNas 默认管理密码（官方默认 admin）。"
compose ps
