#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077

MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install / update" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || {
    if command -v sudo >/dev/null 2>&1; then exec sudo -- bash "$0" "$@"; fi
    echo "请使用 root 或 sudo 运行。" >&2
    exit 1
}
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
CONTAINER=easytier-automation-executor
SERVICE=easytier-automation-executor

die() { printf '执行器部署失败：%s\n' "$*" >&2; exit 1; }
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

command -v docker >/dev/null 2>&1 || die "未安装 Docker"
docker compose version >/dev/null 2>&1 || die "未安装 Docker Compose v2 Plugin"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] ||
    die "独立执行器首版镜像只支持 Linux x86_64（linux/amd64），不支持 OpenWrt ARM"
[ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] ||
    die "统一配置不存在；请先在 deploy 仓库运行 sudo bash deploy.sh env"
[ -f "$COMPOSE_FILE" ] || die "缺少 $COMPOSE_FILE"
chown root:root "$ENV_FILE" "$SECRETS_FILE"
chmod 0600 "$ENV_FILE" "$SECRETS_FILE"

# Parse KEY=VALUE as data, never execute or source values containing shell syntax.
load_config() {
    local file="$1" kind="$2" line key value n=0
    local -A seen=()
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || die "配置格式错误：$file:$n"
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "非法配置变量名：$file:$n"
        if [ "$kind" = env ]; then
            case "$key" in EASYTIER_EXECUTOR_TOKEN|EASYTIER_EXECUTOR_TURN_SECRET)
                die "$key 属于敏感配置，请写入 deploy/.secrets" ;;
                EASYTIER_EXECUTOR_*|TZ) ;;
                *) continue ;;
            esac
        else
            case "$key" in EASYTIER_EXECUTOR_TOKEN|EASYTIER_EXECUTOR_TURN_SECRET) ;;
                *) continue ;;
            esac
        fi
        [[ ! "${seen[$key]+present}" ]] || die "$file 中 $key 重复定义"
        seen[$key]=1
        value="${line#*=}"
        if [ -n "$value" ]; then
            case "${value:0:1}" in
                '"')
                    [ "${#value}" -ge 2 ] && [ "${value: -1}" = '"' ] ||
                        die "$file:$n 双引号未闭合"
                    value="${value:1:${#value}-2}" ;;
                "'")
                    [ "${#value}" -ge 2 ] && [ "${value: -1}" = "'" ] ||
                        die "$file:$n 单引号未闭合"
                    value="${value:1:${#value}-2}" ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
}
load_config "$ENV_FILE" env
load_config "$SECRETS_FILE" secret

EASYTIER_EXECUTOR_IMAGE="${EASYTIER_EXECUTOR_IMAGE:-ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center}"
EASYTIER_EXECUTOR_BIND_IP="${EASYTIER_EXECUTOR_BIND_IP:-127.0.0.1}"
EASYTIER_EXECUTOR_PORT="${EASYTIER_EXECUTOR_PORT:-8766}"
EASYTIER_EXECUTOR_CALLBACK_URL="${EASYTIER_EXECUTOR_CALLBACK_URL:-}"
EASYTIER_EXECUTOR_MAX_RUNNING="${EASYTIER_EXECUTOR_MAX_RUNNING:-3}"
EASYTIER_EXECUTOR_MAX_PENDING="${EASYTIER_EXECUTOR_MAX_PENDING:-30}"
EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS="${EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS:-10}"
EASYTIER_EXECUTOR_MAX_MEDIA_STARTING="${EASYTIER_EXECUTOR_MAX_MEDIA_STARTING:-2}"
EASYTIER_EXECUTOR_ICE_SERVERS="${EASYTIER_EXECUTOR_ICE_SERVERS:-[]}"
EASYTIER_EXECUTOR_TURN_URLS="${EASYTIER_EXECUTOR_TURN_URLS:-[]}"
EASYTIER_EXECUTOR_TURN_TTL_SECONDS="${EASYTIER_EXECUTOR_TURN_TTL_SECONDS:-3600}"
EASYTIER_EXECUTOR_TURN_SECRET="${EASYTIER_EXECUTOR_TURN_SECRET:-}"
TZ="${TZ:-Asia/Shanghai}"

number_in_range() {
    local key="$1" value="$2" min="$3" max="$4"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "${#value}" -le 8 ] &&
      (( 10#$value >= min && 10#$value <= max )) ||
      die "$key 必须为 $min-$max 范围内的整数"
}
number_in_range EASYTIER_EXECUTOR_PORT "$EASYTIER_EXECUTOR_PORT" 1 65535
number_in_range EASYTIER_EXECUTOR_MAX_RUNNING "$EASYTIER_EXECUTOR_MAX_RUNNING" 1 5
number_in_range EASYTIER_EXECUTOR_MAX_PENDING "$EASYTIER_EXECUTOR_MAX_PENDING" 1 100
number_in_range EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS "$EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS" 1 32
number_in_range EASYTIER_EXECUTOR_MAX_MEDIA_STARTING "$EASYTIER_EXECUTOR_MAX_MEDIA_STARTING" 1 4
number_in_range EASYTIER_EXECUTOR_TURN_TTL_SECONDS "$EASYTIER_EXECUTOR_TURN_TTL_SECONDS" 1 86400
[[ "$EASYTIER_EXECUTOR_BIND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    die "EASYTIER_EXECUTOR_BIND_IP 必须是 IPv4 地址"
IFS=. read -r -a ip_parts <<< "$EASYTIER_EXECUTOR_BIND_IP"
for octet in "${ip_parts[@]}"; do
    (( 10#$octet <= 255 )) || die "监听 IP 无效"
done
[[ "$EASYTIER_EXECUTOR_CALLBACK_URL" =~ ^https?://[^/@?#[:space:]]+(/[^?#[:space:]]*)?$ ]] ||
    die "必须在 .env 设置从执行器可达的 EASYTIER_EXECUTOR_CALLBACK_URL（http/https）"
case "$EASYTIER_EXECUTOR_IMAGE" in
    ''|*[[:space:]]*) die "执行器镜像地址无效" ;;
esac
# Prevent accidental takeover of an unrelated manually named container.
existing=0
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    existing=1
    owner="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$CONTAINER")"
    [ "$owner" = easytier-automation-executor ] ||
        die "已存在同名但不属于本部署项目的容器；不会删除或接管它"
else
    # "update" is an idempotent desired-state operation: on an empty host it
    # follows exactly the same first-install path as "install".
    if [ "$MODE" = update ]; then
        echo "未发现已有执行器容器，update 将按首次安装继续；保留已有运行数据和配置。"
    fi
fi

# First install: generate once in the canonical secret file. Never rotate on update.
if [ -z "${EASYTIER_EXECUTOR_TOKEN:-}" ]; then
    [ "$existing" -eq 0 ] || die "已有执行器时 Token 为空；拒绝自动轮换，避免原执行器失联"
    # A stopped or manually removed container may still have a live identity,
    # journal or ADB key. Never silently generate a replacement credential then.
    if [ -d "$BASE_DIR/data/runtime" ] && [ -n "$(find "$BASE_DIR/data/runtime" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        die "检测到已有执行器运行记录但 Token 为空；请恢复 .secrets 中的原 Token"
    fi
    if [ -d "$BASE_DIR/data/adb" ] && [ -n "$(find "$BASE_DIR/data/adb" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        die "检测到已有 ADB 密钥但 Token 为空；请恢复 .secrets 中的原 Token"
    fi
    command -v od >/dev/null 2>&1 || die "缺少 od，无法安全生成 Token"
    generated="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
    [ "${#generated}" -eq 64 ] || die "无法生成随机 Token"
    tmp="$(mktemp "$SECRETS_FILE.tmp.XXXXXXXX")" || die "无法暂存敏感配置"
    found=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*EASYTIER_EXECUTOR_TOKEN[[:space:]]*= ]]; then
            printf 'EASYTIER_EXECUTOR_TOKEN=%s\n' "$generated" >> "$tmp"
            found=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$SECRETS_FILE"
    if [ "$found" -eq 0 ]; then
        printf '\nEASYTIER_EXECUTOR_TOKEN=%s\n' "$generated" >> "$tmp"
    fi
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$SECRETS_FILE"
    EASYTIER_EXECUTOR_TOKEN="$generated"
    echo "首次安装已生成 Token 并仅保存至 $SECRETS_FILE（不会在终端显示）。"
fi
token_bytes="$(printf '%s' "$EASYTIER_EXECUTOR_TOKEN" | wc -c)"
(( token_bytes >= 32 && token_bytes <= 4096 )) &&
    [[ "$EASYTIER_EXECUTOR_TOKEN" != *[[:cntrl:]]* ]] ||
    die "EASYTIER_EXECUTOR_TOKEN 必须为 32-4096 字节且不能包含控制字符"
[ -n "$EASYTIER_EXECUTOR_TURN_SECRET" ] && [ "$EASYTIER_EXECUTOR_TURN_URLS" = '[]' ] &&
    die "设置 TURN_SECRET 时还必须提供 TURN_URLS"
[ -z "$EASYTIER_EXECUTOR_TURN_SECRET" ] && [ "$EASYTIER_EXECUTOR_TURN_URLS" != '[]' ] &&
    die "设置 TURN_URLS 时还必须在 .secrets 提供 TURN_SECRET"

export EASYTIER_EXECUTOR_IMAGE EASYTIER_EXECUTOR_BIND_IP EASYTIER_EXECUTOR_PORT
export EASYTIER_EXECUTOR_CALLBACK_URL EASYTIER_EXECUTOR_TOKEN
export EASYTIER_EXECUTOR_MAX_RUNNING EASYTIER_EXECUTOR_MAX_PENDING
export EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS EASYTIER_EXECUTOR_MAX_MEDIA_STARTING
export EASYTIER_EXECUTOR_ICE_SERVERS EASYTIER_EXECUTOR_TURN_URLS
export EASYTIER_EXECUTOR_TURN_SECRET EASYTIER_EXECUTOR_TURN_TTL_SECONDS TZ

IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] || IMAGE_SOURCES_LIB="$SOFTWARE_ROOT/lib/image-sources.sh"
[ -f "$IMAGE_SOURCES_LIB" ] ||
    die "缺少镜像源公共模块，请从 deploy 根目录运行安装/更新命令"
# shellcheck source=../../lib/image-sources.sh
source "$IMAGE_SOURCES_LIB"
DEPLOY_EASYTIER_EXECUTOR_IMAGE="$EASYTIER_EXECUTOR_IMAGE"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_EASYTIER_EXECUTOR_IMAGE ||
    die "镜像源选择失败"

# Read-only deployment cross-check. Never override another project's image
# setting; simply call out old defaults that lack automation-center fixes.
if docker container inspect easytier >/dev/null 2>&1; then
    running_main_image="$(docker inspect --format '{{.Config.Image}}' easytier 2>/dev/null || true)"
    case "$running_main_image" in
        *:feat-node-attributes-main)
            echo "警告：当前 EasyTier 主容器使用旧分支镜像 $running_main_image" >&2
            echo "      自动化中心修复位于 feat-automation-center；请先确认统一 deploy/.env 的 EASYTIER_IMAGE，再单独更新主服务。" >&2
            ;;
    esac
elif [ "$EASYTIER_EXECUTOR_BIND_IP" = "127.0.0.1" ]; then
    echo "提醒：本机没有发现 EasyTier 主容器，执行器仅监听 127.0.0.1；如果主服务位于另一台服务器，它将无法直接连接此端口。" >&2
fi
echo "独立执行器 $MODE：linux/amd64，网络：host，监听：$EASYTIER_EXECUTOR_BIND_IP:$EASYTIER_EXECUTOR_PORT"
echo "提醒：更新前请在 EasyTier 自动化中心关闭活动投屏，完成或取消运行任务；更新不会自动重放任务。"
compose config --quiet || die "Compose 配置校验未通过（不会输出含 Token 的完整配置）"
# Resolve the Compose image once, and verify it uses the image selected by the
# shared GHCR round-robin rather than accidentally pulling the original tag.
resolved_image="$(compose config --images)" ||
    die "无法读取 Compose 解析后的镜像地址"
[ "$resolved_image" = "$DEPLOY_EASYTIER_EXECUTOR_IMAGE" ] ||
    die "Compose 镜像地址与本轮镜像加速选择不一致；拒绝拉取错误镜像"
echo "本次实际拉取镜像：$resolved_image"
# Pull BEFORE recreating the old container. A failed pull leaves it untouched.
compose pull "$SERVICE" || die "镜像拉取失败；现有容器不受影响"
arch="$(docker image inspect "$DEPLOY_EASYTIER_EXECUTOR_IMAGE" --format '{{.Architecture}}')" ||
    die "无法检查已拉取镜像架构"
[ "$arch" = amd64 ] || die "镜像架构为 $arch，预期 amd64；未更换容器"
# Persist SQLite journal / executor_id / screenshots and ADB identity across upgrades.
install -d -m 0700 -o 10001 -g 10001 "$BASE_DIR/data" "$BASE_DIR/data/runtime" "$BASE_DIR/data/adb"
compose up -d --no-deps --force-recreate --pull never "$SERVICE" ||
    die "执行器启动失败；数据目录未删除，请使用 docker logs $CONTAINER 检查"
# Only authenticate inside the container; do not pass the private token on the host command line.
ready=0
for attempt in $(seq 1 25); do
    status="$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
    case "$status" in exited|dead) break ;; esac
    if docker exec -e EASYTIER_EXECUTOR_BIND_IP="$EASYTIER_EXECUTOR_BIND_IP" -e EASYTIER_EXECUTOR_PORT="$EASYTIER_EXECUTOR_PORT" "$CONTAINER" python -c '
import json, os, urllib.request
from automation_executor.auth import authorization
ip = os.environ.get("EASYTIER_EXECUTOR_BIND_IP", "127.0.0.1")
if ip == "0.0.0.0": ip = "127.0.0.1"
port = os.environ.get("EASYTIER_EXECUTOR_PORT", "8766")
request = urllib.request.Request("http://%s:%s/internal/v1/health" % (ip, port), headers={"Authorization": authorization(os.environ["AUTOMATION_TOKEN"])})
response = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2)
data = json.load(response)
assert data["protocol_version"] == 1 and data["executor_id"] and data["state"] == "ready"
' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "执行器未通过内部认证健康检查；以下仅为容器状态（不输出 Token）。" >&2
    compose ps || true
    die "请检查 docker logs $CONTAINER；不会删除数据或 ADB 授权密钥"
fi
compose ps
echo "已启动。主服务管理员在「自动化中心 → 设置」填写 http://<执行器可达IP>:$EASYTIER_EXECUTOR_PORT 及 .secrets 中的 EASYTIER_EXECUTOR_TOKEN，点击检查已保存连接。"
echo "健康检查仅证明接口/身份可用；Android 配对、WebRTC 首帧仍需在实机检查。"
