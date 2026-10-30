#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077

MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install / update" >&2; exit 2 ;; esac

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
SERVICE=webtop
CONTAINER=webtop

# shellcheck source=./lib.sh
source "$DEPLOY_DIR/lib.sh"

require_root "$@"
check_docker
load_global_config

WEBTOP_IMAGE="${WEBTOP_IMAGE:-lscr.io/linuxserver/webtop:debian-xfce}"
WEBTOP_BIND_IP="${WEBTOP_BIND_IP:-127.0.0.1}"
WEBTOP_PORT="${WEBTOP_PORT:-7014}"
WEBTOP_PUID="${WEBTOP_PUID:-1000}"
WEBTOP_PGID="${WEBTOP_PGID:-1000}"
WEBTOP_LOCALE="${WEBTOP_LOCALE:-zh_CN.UTF-8}"
WEBTOP_SHM_SIZE="${WEBTOP_SHM_SIZE:-1gb}"
WEBTOP_CUSTOM_USER="${WEBTOP_CUSTOM_USER:-}"
WEBTOP_PASSWORD="${WEBTOP_PASSWORD:-}"
TZ="${TZ:-Asia/Shanghai}"

case "$WEBTOP_IMAGE" in ''|*[[:space:]]*) fail "WEBTOP_IMAGE 不能为空或包含空白" ;; esac
validate_ipv4 WEBTOP_BIND_IP "$WEBTOP_BIND_IP"
validate_port WEBTOP_PORT "$WEBTOP_PORT"
[[ "$WEBTOP_PUID" =~ ^[0-9]+$ ]] || fail "WEBTOP_PUID 必须是数字"
[[ "$WEBTOP_PGID" =~ ^[0-9]+$ ]] || fail "WEBTOP_PGID 必须是数字"

if { [ -n "$WEBTOP_CUSTOM_USER" ] && [ -z "$WEBTOP_PASSWORD" ]; } ||
   { [ -z "$WEBTOP_CUSTOM_USER" ] && [ -n "$WEBTOP_PASSWORD" ]; }; then
    fail "启用 Webtop 登录认证时，WEBTOP_CUSTOM_USER 与 WEBTOP_PASSWORD 必须同时设置；两者都留空则不启用认证"
fi
if [[ "$WEBTOP_BIND_IP" != 127.* ]] && [ -z "$WEBTOP_PASSWORD" ]; then
    echo "安全提醒：当前 Webtop 监听非回环地址且未启用登录认证；请限制可信网络访问，或配置 WEBTOP_CUSTOM_USER / WEBTOP_PASSWORD。" >&2
fi

verify_container_owner "$CONTAINER" webtop
if [ "$MODE" = update ] && ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    fail "未找到现有 Webtop 容器，请先执行 install"
fi

install -d -m 0750 -o "$WEBTOP_PUID" -g "$WEBTOP_PGID" "$BASE_DIR/data/config" "$BASE_DIR/data/shared"

IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || fail "缺少公共镜像源模块，请从 deploy 仓库根目录执行同步/安装"
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"

DEPLOY_WEBTOP_IMAGE="$WEBTOP_IMAGE"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_WEBTOP_IMAGE

export DEPLOY_WEBTOP_IMAGE WEBTOP_BIND_IP WEBTOP_PORT WEBTOP_PUID WEBTOP_PGID
export WEBTOP_LOCALE WEBTOP_SHM_SIZE WEBTOP_CUSTOM_USER WEBTOP_PASSWORD TZ

compose() {
    docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

compose config --quiet || fail "Compose 配置校验失败"
resolved_image="$(compose config --images)" || fail "无法读取 Compose 解析后的镜像地址"
[ "$resolved_image" = "$DEPLOY_WEBTOP_IMAGE" ] || fail "Compose 镜像地址与本次镜像源选择不一致；拒绝拉取错误镜像"

echo "Webtop $MODE：准备拉取 $resolved_image"
compose pull "$SERVICE" || fail "镜像拉取失败；现有容器保持不变"
compose up -d --no-deps --force-recreate --pull never --wait --wait-timeout 180 "$SERVICE" ||
    fail "Webtop 未能成功启动；数据目录已保留，请检查 docker logs $CONTAINER"

compose ps
if [[ "$WEBTOP_BIND_IP" == 127.* ]]; then
    echo "Webtop 已启动，仅本机监听：https://127.0.0.1:$WEBTOP_PORT/"
else
    echo "Webtop 已启动：https://<NAS-IP>:$WEBTOP_PORT/"
fi
echo "注意：上游使用自签名 HTTPS 证书，首次访问时浏览器可能提示证书风险。"
echo "持久化目录：$BASE_DIR/data/config；共享目录：$BASE_DIR/data/shared（桌面内路径 /shared）"
