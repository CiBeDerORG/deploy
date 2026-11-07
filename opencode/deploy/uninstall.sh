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
if docker inspect opencode >/dev/null 2>&1; then
  work="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' opencode)"
  project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' opencode)"
  config="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' opencode)"
  [[ "$project" == opencode && "$work" == "$HERE" && "$config" == "$HERE/docker-compose.yaml" ]] ||
    { echo "同名 OpenCode 容器不属于当前部署目录，拒绝卸载" >&2; exit 1; }
fi
docker compose -p opencode -f "$HERE/docker-compose.yaml" down
echo "OpenCode 容器已移除；配置、密码、工作空间与持久化数据均保留。"
