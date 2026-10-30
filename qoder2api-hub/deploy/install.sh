#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install / update" >&2; exit 2 ;; esac
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
CONTAINER=qoder2api-hub
SERVICE=qoder2api-hub
# shellcheck source=./lib.sh
source "$DEPLOY_DIR/lib.sh"
require_root "$@"
check_docker
load_global_config
QODER2API_HUB_IMAGE="${QODER2API_HUB_IMAGE:-ghcr.io/shuishuipingan/qoder2api-hub:latest}"
QODER2API_HUB_BIND_IP="${QODER2API_HUB_BIND_IP:-127.0.0.1}"
QODER2API_HUB_PORT="${QODER2API_HUB_PORT:-8790}"
QODER2API_HUB_API_KEY="${QODER2API_HUB_API_KEY:-}"
QODER2API_HUB_HTTP_PROXY="${QODER2API_HUB_HTTP_PROXY:-}"
QODER2API_HUB_HTTPS_PROXY="${QODER2API_HUB_HTTPS_PROXY:-}"
QODER2API_HUB_ALL_PROXY="${QODER2API_HUB_ALL_PROXY:-}"
TZ="${TZ:-Asia/Shanghai}"
case "$QODER2API_HUB_IMAGE" in ''|*[[:space:]]*) fail "QODER2API_HUB_IMAGE 不能为空或包含空白" ;; esac
validate_port QODER2API_HUB_PORT "$QODER2API_HUB_PORT"
validate_ipv4 QODER2API_HUB_BIND_IP "$QODER2API_HUB_BIND_IP"
verify_container_owner "$CONTAINER" qoder2api-hub
if [ "$MODE" = update ] && ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    fail "未找到现有 Qoder2API Hub 容器，请先执行 install"
fi
install -d -m 0700 "$BASE_DIR/data/accounts" "$BASE_DIR/data/usage"
IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || fail "缺少公共镜像源模块，请从 deploy 仓库根目录执行同步/安装"
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
DEPLOY_QODER2API_HUB_IMAGE="$QODER2API_HUB_IMAGE"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_QODER2API_HUB_IMAGE
export QODER2API_HUB_BIND_IP QODER2API_HUB_PORT QODER2API_HUB_API_KEY
export QODER2API_HUB_HTTP_PROXY QODER2API_HUB_HTTPS_PROXY QODER2API_HUB_ALL_PROXY
export DEPLOY_QODER2API_HUB_IMAGE TZ
compose() {
    docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}
compose config --quiet || fail "Compose 配置校验失败"
resolved_image="$(compose config --images)" || fail "无法读取 Compose 解析后的镜像地址"
[ "$resolved_image" = "$DEPLOY_QODER2API_HUB_IMAGE" ] || fail "Compose 镜像地址与本次镜像源选择不一致；拒绝拉取错误镜像"
echo "Qoder2API Hub $MODE：准备拉取 $resolved_image"
compose pull "$SERVICE" || fail "镜像拉取失败；现有容器保持不变"
compose up -d --no-deps --force-recreate --pull never --wait --wait-timeout 120 "$SERVICE" ||
    fail "容器未通过健康检查；数据目录已保留，请检查 docker logs $CONTAINER"
compose ps
echo "Qoder2API Hub 已启动：http://$QODER2API_HUB_BIND_IP:$QODER2API_HUB_PORT"
if [ -z "$QODER2API_HUB_API_KEY" ]; then
    echo 'API Key 留空：首次启动由上游自动生成；读取命令：docker logs qoder2api-hub 2>&1 | grep -i "api key"'
fi
echo "安全提醒：上游面板初始密码为 admin；首次登录后立即修改。"
