#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo "Mihomo 卸载需要 root 权限" >&2; exit 1; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
