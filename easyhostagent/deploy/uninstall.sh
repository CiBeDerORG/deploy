#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo "EasyHostAgent 卸载需要 root 权限" >&2; exit 1; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$MODULE/.." && pwd)"
command -v flock >/dev/null || { echo "缺少 flock" >&2; exit 1; }
mkdir -p "$SOFTWARE_ROOT/deploy/state"
exec 8>"$SOFTWARE_ROOT/deploy/state/easyhostagent.lock"
flock -n 8 || { echo "已有 EasyHostAgent 操作正在运行" >&2; exit 1; }
docker compose version >/dev/null || { echo "Docker Compose 不可用" >&2; exit 1; }

owned="$(docker ps -a --filter label=com.docker.compose.project=easyhostagent --format '{{.Names}}')"
while IFS= read -r name; do
    case "$name" in ''|easyhostagent) ;; *) echo "发现未知的同项目容器，拒绝卸载" >&2; exit 1 ;; esac
done <<< "$owned"
if docker container inspect easyhostagent >/dev/null 2>&1; then
    grep -Fxq easyhostagent <<< "$owned" || { echo "同名容器不属于本部署" >&2; exit 1; }
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' easyhostagent)"
    directory="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' easyhostagent)"
    [[ "$service" == easyhostagent && "$directory" == "$HERE" ]] ||
        { echo "容器归属不匹配，拒绝卸载" >&2; exit 1; }
fi
docker compose --env-file /dev/null --project-name easyhostagent --project-directory "$HERE" \
    -f "$HERE/docker-compose.yaml" down --remove-orphans
echo "EasyHostAgent 容器已卸载；保留数据目录、配对状态、已安装的 Docker 应用、镜像与统一配置。"
