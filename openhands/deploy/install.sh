#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install/update" >&2; exit 2;; esac

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
# shellcheck source=./lib.sh
source "$DEPLOY_DIR/lib.sh"
require_root "$@"
check_docker
load_config

OPENHANDS_IMAGE="${OPENHANDS_IMAGE:-ghcr.io/openhands/agent-canvas:latest}"
OPENHANDS_BIND_IP="${OPENHANDS_BIND_IP:-0.0.0.0}"
OPENHANDS_PORT="${OPENHANDS_PORT:-7016}"
OPENHANDS_API_KEY="${OPENHANDS_API_KEY:-}"
TZ="${TZ:-Asia/Shanghai}"
validate_config
check_container_owner

if [ -z "$OPENHANDS_API_KEY" ]; then
  command -v openssl >/dev/null 2>&1 || fail "API Key 留空且缺少 openssl"
  OPENHANDS_API_KEY="$(openssl rand -hex 32)" || fail "随机密钥生成失败"
  [ -n "$OPENHANDS_API_KEY" ] || fail "随机密钥生成失败"
  persist_generated_api_key
  echo "已生成并保存 OPENHANDS_API_KEY 至 deploy/.secrets，更新不会重置"
fi

# The official container user is UID/GID 10001; preserve existing files.
install -d -m 0700 -o 10001 -g 10001 "$BASE_DIR/data"
install -d -m 0750 -o 10001 -g 10001 "$BASE_DIR/workspace"

IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || fail "缺少公共镜像加速模块，请通过 deploy.sh 同步"
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
DEPLOY_OPENHANDS_IMAGE="$OPENHANDS_IMAGE"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_OPENHANDS_IMAGE || fail "镜像来源准备失败"
export OPENHANDS_BIND_IP OPENHANDS_PORT OPENHANDS_API_KEY DEPLOY_OPENHANDS_IMAGE TZ

compose() {
  docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}
compose config --quiet || fail "Compose 配置校验失败"
resolved="$(compose config --images)" || fail "无法解析镜像"
[ "$resolved" = "$DEPLOY_OPENHANDS_IMAGE" ] || fail "解析镜像与加速源不一致"

echo "OpenHands Agent Canvas $MODE，拉取镜像 $resolved"
compose pull openhands || fail "镜像拉取失败，现有容器未变"
if ! compose up -d --no-deps --force-recreate --pull never --wait --wait-timeout 180 openhands; then
  # Fail closed: an unprotected Agent API must not remain accessible after
  # failed startup/authentication health checks.
  echo "OpenHands 启动或鉴权健康检查失败；正在停止容器，防止未授权 API 暴露" >&2
  compose down || true
  fail "容器启动或 API 鉴权检查失败，请检查 docker logs（容器已尝试停止）"
fi
# Verify the actual protected endpoint rejects requests without a key and
# accepts only the configured credential. Never expose the secret in argv/logs.
if ! docker exec openhands node -e '
  const url = "http://127.0.0.1:8000/api/conversations/search";
  Promise.all([
    fetch(url),
    fetch(url, {headers: {"X-Session-API-Key": process.env.OH_SESSION_API_KEYS_0}})
  ]).then(([anonymous, authorized]) => {
    if (anonymous.status !== 401 || authorized.status !== 200) {
      console.error("OpenHands API auth check failed (anonymous/authorized HTTP):", anonymous.status, authorized.status);
      process.exit(1);
    }
  }).catch(() => process.exit(1));
'; then
  echo "OpenHands API 访问控制异常；正在停止容器，防止未授权 API 暴露" >&2
  compose down || true
  fail "Agent Server API 密钥鉴权未通过，服务已尝试停止"
fi
compose ps
echo "OpenHands 已启动：http://$OPENHANDS_BIND_IP:$OPENHANDS_PORT/canvas"
echo "登录密钥在 $SECRETS_FILE 的 OPENHANDS_API_KEY"
echo "工作目录为 $BASE_DIR/workspace（容器内 /projects）"
if [ "$OPENHANDS_BIND_IP" = 0.0.0.0 ]; then
  echo "安全提示：务必用防火墙限制局域网/EasyTier 来源，不要直接将 HTTP 服务开放到公网"
fi
