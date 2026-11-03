#!/usr/bin/env bash
# 使用本业务 Deploy 封装执行 Compose down；保留账号、用量及密钥配置。
set -Eeuo pipefail
umask 077
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
# shellcheck source=./lib.sh
source "$DEPLOY_DIR/lib.sh"
require_root "$@"
check_docker
load_global_config
verify_container_owner "qoder2api-hub" "qoder2api-hub"
QODER2API_HUB_IMAGE="${QODER2API_HUB_IMAGE:-ghcr.io/shuishuipingan/qoder2api-hub:latest}"
QODER2API_HUB_BIND_IP="${QODER2API_HUB_BIND_IP:-127.0.0.1}"
QODER2API_HUB_PORT="${QODER2API_HUB_PORT:-8790}"
QODER2API_HUB_API_KEY="${QODER2API_HUB_API_KEY:-}"
QODER2API_HUB_HTTP_PROXY="${QODER2API_HUB_HTTP_PROXY:-}"
QODER2API_HUB_HTTPS_PROXY="${QODER2API_HUB_HTTPS_PROXY:-}"
QODER2API_HUB_ALL_PROXY="${QODER2API_HUB_ALL_PROXY:-}"
TZ="${TZ:-Asia/Shanghai}"
export QODER2API_HUB_IMAGE QODER2API_HUB_BIND_IP QODER2API_HUB_PORT QODER2API_HUB_API_KEY
export QODER2API_HUB_HTTP_PROXY QODER2API_HUB_HTTPS_PROXY QODER2API_HUB_ALL_PROXY TZ
docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" \
    -f "$DEPLOY_DIR/docker-compose.yaml" down
echo "Qoder2API Hub 已卸载，账号和用量数据保留于 $BASE_DIR/data"
