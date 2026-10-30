#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then exec sudo -- bash "$0" "$@"; fi
  echo "需要 root 权限" >&2; exit 1
fi
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install/update" >&2; exit 2;; esac
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
fail() { echo "Webtop：$*" >&2; exit 1; }
load_config() {
  local file="$1" line key value n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue;; esac
    [[ "$line" == *=* ]] || fail "$file:$n 配置必须是 KEY=VALUE"
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "$file:$n 变量名非法"
    if [ -n "$value" ]; then
      case "${value:0:1}" in
        '"') [ "${value: -1}" = '"' ] || fail "$file:$n 引号不匹配"; value="${value:1:${#value}-2}";;
        "'") [ "${value: -1}" = "'" ] || fail "$file:$n 引号不匹配"; value="${value:1:${#value}-2}";;
      esac
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"
}
command -v docker >/dev/null || fail "缺少 Docker"
docker compose version >/dev/null 2>&1 || fail "缺少 Docker Compose v2"
docker info >/dev/null 2>&1 || fail "Docker 服务不可用"
[ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] || fail "请先执行 sudo bash deploy.sh env"
load_config "$ENV_FILE"
load_config "$SECRETS_FILE"
WEBTOP_IMAGE="${WEBTOP_IMAGE:-lscr.io/linuxserver/webtop:debian-xfce}"
WEBTOP_HTTPS_PORT="${WEBTOP_HTTPS_PORT:-7014}"
WEBTOP_BIND_IP="${WEBTOP_BIND_IP:-0.0.0.0}"
WEBTOP_PUID="${WEBTOP_PUID:-1000}"
WEBTOP_PGID="${WEBTOP_PGID:-1000}"
WEBTOP_USER="${WEBTOP_USER:-desktop}"
TZ="${TZ:-Asia/Shanghai}"
[ -n "$WEBTOP_IMAGE" ] && [[ ! "$WEBTOP_IMAGE" =~ [[:space:]] ]] || fail "镜像地址非法"
[[ "$WEBTOP_HTTPS_PORT" =~ ^[0-9]+$ ]] && ((10#$WEBTOP_HTTPS_PORT >= 1 && 10#$WEBTOP_HTTPS_PORT <= 65535)) || fail "端口非法"
[[ "$WEBTOP_BIND_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail "仅支持 IPv4 绑定地址"
[[ "$WEBTOP_PUID" =~ ^[0-9]+$ ]] && [[ "$WEBTOP_PGID" =~ ^[0-9]+$ ]] || fail "PUID/PGID 必须为数字"
[[ "$WEBTOP_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || fail "Webtop 用户名格式非法"
if docker inspect webtop >/dev/null 2>&1; then
  project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' webtop 2>/dev/null || true)"
  [ "$project" = webtop ] || fail "存在不属于本项目的 webtop 容器，拒绝覆盖"
elif [ "$MODE" = update ]; then
  fail "没有已安装的 Webtop，请先运行 sudo bash deploy.sh webtop"
fi
if [ -z "${WEBTOP_PASSWORD:-}" ]; then
  command -v openssl >/dev/null || fail "WEBTOP_PASSWORD 未设置且缺少 openssl，无法安全生成密码"
  WEBTOP_PASSWORD="$(openssl rand -hex 24)"
  # 空值存在时先删除；所有生成值均为安全的十六进制字符串。
  sed -i '/^WEBTOP_PASSWORD=/d' "$SECRETS_FILE"
  printf '\nWEBTOP_PASSWORD=%s\n' "$WEBTOP_PASSWORD" >> "$SECRETS_FILE"
  chmod 0600 "$SECRETS_FILE"
  echo "已生成 Webtop 登录密码并保存在 $SECRETS_FILE（不在日志中打印）"
fi
[ -n "$WEBTOP_PASSWORD" ] || fail "登录密码不能为空"
install -d -m 0700 "$BASE_DIR/state" "$BASE_DIR/data"
printf '%s' "$WEBTOP_PASSWORD" > "$BASE_DIR/state/webtop_password"
chmod 0600 "$BASE_DIR/state/webtop_password"
DEPLOY_WEBTOP_IMAGE="$WEBTOP_IMAGE"
IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || fail "缺少公共镜像源模块，请通过根 deploy.sh 安装"
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_WEBTOP_IMAGE
export DEPLOY_WEBTOP_IMAGE WEBTOP_BIND_IP WEBTOP_HTTPS_PORT WEBTOP_PUID WEBTOP_PGID WEBTOP_USER TZ
compose() { docker compose --project-name webtop --project-directory "$DEPLOY_DIR" -f "$COMPOSE_FILE" "$@"; }
compose config --quiet || fail "Compose 配置校验失败"
[ "$(compose config --images)" = "$DEPLOY_WEBTOP_IMAGE" ] || fail "Compose 镜像解析错误"
echo "Webtop $MODE：拉取 $DEPLOY_WEBTOP_IMAGE"
compose pull webtop || fail "拉取失败，原有容器不变"
compose up -d --no-deps --force-recreate --pull never webtop || fail "启动失败；请查看 docker logs webtop"
echo "Webtop 已部署，访问 https://<NAS-IP>:$WEBTOP_HTTPS_PORT/ （自签名证书）"
echo "用户名：$WEBTOP_USER；密码保存在 $SECRETS_FILE"
compose ps
