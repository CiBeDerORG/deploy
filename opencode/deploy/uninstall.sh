#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo "OpenCode 卸载需要 root 权限" >&2; exit 1; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
