#!/usr/bin/env bash
# Deploy 受控应用卸载入口：只停止并删除本项目 Compose 容器/网络，保留数据和密钥。
set -Eeuo pipefail
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
export SUB2API_HTTP_PORT="${SUB2API_HTTP_PORT:-7010}"
export SUB2API_BIND_IP="${SUB2API_BIND_IP:-0.0.0.0}"
for name in sub2api sub2api-postgres sub2api-redis; do
    verify_container_owner "$name" sub2api
done
cd "$DEPLOY_DIR"
# 仅执行 Compose down，不请求删除卷或用户数据目录。
docker compose -f "$DEPLOY_DIR/docker-compose.yaml" down
echo "Sub2API 已卸载，数据与配置保留于 $BASE_DIR"
