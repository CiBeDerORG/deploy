#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install/update" >&2; exit 1 ;; esac
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
SUB2API_HTTP_PORT="${SUB2API_HTTP_PORT:-7010}"
SUB2API_BIND_IP="${SUB2API_BIND_IP:-0.0.0.0}"
validate_port SUB2API_HTTP_PORT "$SUB2API_HTTP_PORT"
validate_ipv4 SUB2API_BIND_IP "$SUB2API_BIND_IP"
for key in SUB2API_POSTGRES_PASSWORD SUB2API_REDIS_PASSWORD SUB2API_JWT_SECRET SUB2API_TOTP_ENCRYPTION_KEY; do
    ensure_hex_secret "$key"
done
# Upstream AutoSetupFromEnv independently generates an omitted admin email
# or password. Do not impose an extra "both-or-neither" wrapper requirement.
# Nonempty email is validated by upstream; only enforce its documented
# 8-72 UTF-8 byte password constraint for a user-supplied nonempty password.
SUB2API_ADMIN_EMAIL="${SUB2API_ADMIN_EMAIL:-}"
SUB2API_ADMIN_PASSWORD="${SUB2API_ADMIN_PASSWORD:-}"
if [ -n "$SUB2API_ADMIN_PASSWORD" ]; then
    validate_upstream_admin_password "$SUB2API_ADMIN_PASSWORD"
fi
export SUB2API_HTTP_PORT SUB2API_BIND_IP SUB2API_ADMIN_EMAIL SUB2API_ADMIN_PASSWORD
for name in sub2api sub2api-postgres sub2api-redis; do verify_container_owner "$name" sub2api; done
if [ "$MODE" = update ]; then
    docker container inspect sub2api >/dev/null 2>&1 || fail "找不到现有 Sub2API，请先安装"
    [ -d "$BASE_DIR/data/postgres" ] || fail "PostgreSQL 数据目录缺失，已中止，防止意外初始化新数据库"
fi
install -d -m 0700 "$BASE_DIR/data" "$BASE_DIR/data/app" "$BASE_DIR/data/postgres" "$BASE_DIR/data/redis"
cd "$DEPLOY_DIR"
compose() { docker compose -f "$DEPLOY_DIR/docker-compose.yaml" "$@"; }
compose config --quiet || fail "Compose 配置校验失败"
compose pull
echo "正在${MODE} Sub2API、PostgreSQL 和 Redis..."
if ! compose up -d --wait --wait-timeout 180; then
    compose ps || true
    compose logs --tail=80 || true
    fail "服务未在等待窗口内全部健康，请检查日志"
fi
echo "Sub2API 已启动：http://<服务器IP>:$SUB2API_HTTP_PORT（绑定 $SUB2API_BIND_IP）"
echo "持久化目录：$BASE_DIR/data"
if [ -z "$SUB2API_ADMIN_EMAIL" ] || [ -z "$SUB2API_ADMIN_PASSWORD" ]; then echo "首次管理员缺省凭据由官方生成：请查看 sudo docker logs sub2api 并妥善保存。"; fi
compose ps
