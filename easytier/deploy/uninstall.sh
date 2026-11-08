#!/usr/bin/env bash
set -Eeuo pipefail
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOFTWARE_ROOT="$(cd -- "$DEPLOY_DIR/../.." && pwd)"
PLATFORM_LIB="$SOFTWARE_ROOT/deploy/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || PLATFORM_LIB="$SOFTWARE_ROOT/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || { echo "缺少跨平台 Deploy 辅助脚本。" >&2; exit 1; }
source "$PLATFORM_LIB"
deploy_require_root || exit 1
command -v docker >/dev/null && docker compose version >/dev/null || { echo "Docker Compose 不可用" >&2; exit 1; }
if docker inspect easytier >/dev/null 2>&1; then
    project="$(docker inspect --format='{{ index .Config.Labels "com.docker.compose.project" }}' easytier)"
    work="$(docker inspect --format='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' easytier)"
    [ "$project" = easytier ] && [ "$work" = "$DEPLOY_DIR" ] || {
        echo "同名容器不是本部署项目，拒绝卸载。" >&2; exit 1;
    }
fi
docker compose -p easytier -f "$DEPLOY_DIR/docker-compose.yaml" down
echo "EasyTier 容器已卸载；config、data、旧配置和镜像仍保留。"
