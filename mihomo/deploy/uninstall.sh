#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
PLATFORM_LIB="$SOFTWARE_ROOT/deploy/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || PLATFORM_LIB="$SOFTWARE_ROOT/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || { echo "缺少跨平台 Deploy 辅助脚本。" >&2; exit 1; }
# shellcheck source=../../lib/platform.sh
source "$PLATFORM_LIB"
deploy_require_root || exit 1
command -v docker >/dev/null && docker compose version >/dev/null || { echo "Docker Compose 不可用" >&2; exit 1; }
if docker inspect mihomo >/dev/null 2>&1; then
  work="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' mihomo)"
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' mihomo)"
  config="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' mihomo)"
  [[ "$project" == mihomo && "$work" == "$HERE" && "$config" == "$HERE/docker-compose.yaml" ]] ||
    { echo "同名 Mihomo 容器不属于当前部署目录，拒绝卸载" >&2; exit 1; }
fi
docker compose -p mihomo -f "$HERE/docker-compose.yaml" down
echo "Mihomo 容器已移除；配置、凭据、数据与共享 proxy-net 均保留。"
