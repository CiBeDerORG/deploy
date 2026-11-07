#!/usr/bin/env bash
# 只卸载本项目 Compose 资源；绝不删除 Portainer 数据或管理凭据。
set -Eeuo pipefail
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
PLATFORM_LIB="$SOFTWARE_ROOT/deploy/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || PLATFORM_LIB="$SOFTWARE_ROOT/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || { echo "缺少跨平台 Deploy 辅助脚本。" >&2; exit 1; }
# shellcheck source=../../lib/platform.sh
source "$PLATFORM_LIB"
deploy_require_root || exit 1
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
if [ -f "$BASE_DIR/deploy/config.env.example" ]; then
    CONFIG_LIB="$SOFTWARE_ROOT/deploy/lib/app-config.sh"
    [ -f "$CONFIG_LIB" ] || CONFIG_LIB="$SOFTWARE_ROOT/lib/app-config.sh"
    # shellcheck source=../../lib/app-config.sh
    source "$CONFIG_LIB"
    deploy_load_app_config "$SOFTWARE_ROOT" "$(basename "$BASE_DIR")"
fi
[[ -f "$ENV_FILE" && -f "$SECRETS_FILE" ]] || { echo "缺少 Deploy 统一配置" >&2; exit 1; }
docker compose version >/dev/null
docker info >/dev/null
if docker container inspect portainer >/dev/null 2>&1; then
    actual="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' portainer)"
    [[ "$actual" == portainer ]] || { echo "同名容器不属于 Portainer 项目，拒绝卸载" >&2; exit 1; }
fi
docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" \
    --env-file "$SECRETS_FILE" -f "$DEPLOY_DIR/docker-compose.yaml" down
echo "Portainer 已卸载，数据目录 $BASE_DIR/data 已保留"
