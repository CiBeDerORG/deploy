#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$DEPLOY_DIR/lib.sh"
require_root "$@"
check_docker

# Never delete or take over a similarly named container from another project.
if docker container inspect openhands >/dev/null 2>&1; then
  project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' openhands 2>/dev/null || true)"
  [ "$project" = openhands ] ||
    fail "容器 openhands 不属于本部署项目，拒绝卸载"
fi

# Compose needs syntactically valid interpolation values even for 'down'.
# Do not load secrets or inject the user's real API Key during uninstall.
export DEPLOY_OPENHANDS_IMAGE=ghcr.io/openhands/agent-canvas:latest
export OPENHANDS_API_KEY=uninstall-only-placeholder
docker compose --project-directory "$DEPLOY_DIR" \
  -f "$DEPLOY_DIR/docker-compose.yaml" down ||
  fail "卸载容器失败，请查看 Docker 日志"

echo "OpenHands 容器及其 Compose 专属网络已移除。"
echo "持久化数据、工作区、统一 .env/.secrets 和镜像均予保留。"
