#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set +ax
set -Eeuo pipefail
umask 077
fail() { printf 'EasyNetTopo：%s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )); then exec sudo -- bash "$0" "$@"; fi
mode="${1:-install}"
case "$mode" in install|update|uninstall) ;; *) fail "支持 install、update、uninstall" ;; esac
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
source "$DEPLOY_DIR/config.sh"

# 凭据只从 .secrets 读取；普通设置只从统一 .env 读取。
unset EASYNETTOPO_ADMIN_USERNAME EASYNETTOPO_ADMIN_PASSWORD EASYNETTOPO_IMAGE EASYNETTOPO_HTTP_PORT EASYNETTOPO_BIND_IP
unset EASYNETTOPO_GIT_ALLOWED_HOSTS EASYNETTOPO_GIT_ALLOW_HTTP TZ
[[ -f "$ENV_FILE" ]] || fail "请先执行 sudo bash deploy.sh env"
load_settings "$ENV_FILE" env
source "$SOFTWARE_ROOT/deploy/lib/versions.sh"
deploy_load_versions "$SOFTWARE_ROOT" || exit 1
export EASYNETTOPO_HTTP_PORT="${EASYNETTOPO_HTTP_PORT:-7017}"
export EASYNETTOPO_BIND_IP="${EASYNETTOPO_BIND_IP:-0.0.0.0}"
export EASYNETTOPO_GIT_ALLOWED_HOSTS="${EASYNETTOPO_GIT_ALLOWED_HOSTS:-github.com}"
export EASYNETTOPO_GIT_ALLOW_HTTP="${EASYNETTOPO_GIT_ALLOW_HTTP:-false}"
export TZ="${TZ:-Asia/Shanghai}"
export DEPLOY_EASYNETTOPO_IMAGE="$EASYNETTOPO_IMAGE"
[[ "$EASYNETTOPO_HTTP_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$EASYNETTOPO_HTTP_PORT >= 1 && 10#$EASYNETTOPO_HTTP_PORT <= 65535 )) ||
    fail "端口应为 1–65535 的整数"
# 仅接受有效的 IPv4 主机绑定地址，避免 Compose 误解析端口或配置注入。
[[ "$EASYNETTOPO_BIND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "EASYNETTOPO_BIND_IP 必须为 IPv4 地址（如 0.0.0.0 或 127.0.0.1）"
IFS='.' read -r -a bind_octets <<< "$EASYNETTOPO_BIND_IP"
for octet in "${bind_octets[@]}"; do
    (( 10#$octet <= 255 )) || fail "EASYNETTOPO_BIND_IP 含无效的 IPv4 地址段"
done
[[ "$DEPLOY_EASYNETTOPO_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/@:-]*$ ]] || fail "镜像引用无效"
case "$EASYNETTOPO_GIT_ALLOW_HTTP" in true|false) ;; *) fail "EASYNETTOPO_GIT_ALLOW_HTTP 只能填 true 或 false" ;; esac

compose() {
    docker compose --env-file /dev/null --project-name easynettopo --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/docker-compose.yaml" "$@"
}

verify_ownership() {
    local owned name service directory expected
    owned="$(docker ps -a --filter label=com.docker.compose.project=easynettopo --format '{{.Names}}')" ||
        fail "读取 Compose 项目失败"
    while IFS= read -r name; do
        case "$name" in ''|easynettopo|easynettopo-gateway) ;; *) fail "同名 Compose 项目含有额外容器，已停止操作" ;; esac
    done <<< "$owned"
    for name in easynettopo easynettopo-gateway; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            grep -Fxq "$name" <<< "$owned" || fail "同名容器 $name 不属于本项目"
            expected=easynettopo
            [[ "$name" != easynettopo-gateway ]] || expected=gateway
            service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$name")"
            directory="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name")"
            [[ "$service" == "$expected" && "$directory" == "$DEPLOY_DIR" ]] || fail "$name 属于其他部署目录或服务"
        fi
    done
}

ensure_private_dir() {
    local dir="$1"
    [[ ! -L "$dir" ]] || fail "$dir 不得是符号链接"
    if [[ ! -e "$dir" ]]; then
        mkdir -m 0700 -- "$dir"
        chown 10001:10001 -- "$dir"
    fi
    [[ -d "$dir" && "$(stat -c '%u:%g:%a' "$dir")" == 10001:10001:700 ]] ||
        fail "已有目录 $dir 需归 UID/GID 10001:10001 所有且权限为 0700"
}

docker compose version >/dev/null || fail "需要 Docker Compose v2 或以上"
docker info >/dev/null || fail "Docker 服务不可用"
mkdir -p -- "$SOFTWARE_ROOT/deploy/state"
exec 8>"$SOFTWARE_ROOT/deploy/state/easynettopo.lock"
flock -n 8 || fail "本机已有 EasyNetTopo 部署操作正在运行"
verify_ownership

if [[ "$mode" == uninstall ]]; then
    # 连同旧版双容器部署遗留的 gateway 一并移除，不影响其他 Compose 项目。
    compose down --remove-orphans
    echo "EasyNetTopo 已卸载，数据库、SSH 配置和统一配置均已保留。"
    exit 0
fi
if [[ "$mode" == update && ! -f "$BASE_DIR/data/app.db" ]]; then
    fail "没有已安装的数据库，请先执行 install"
fi
ensure_private_dir "$BASE_DIR/data"
ensure_private_dir "$BASE_DIR/ssh"

# 安装和更新只选一次镜像站；配置、拉取和启动共用这次解析得到的镜像引用。
source "$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_EASYNETTOPO_IMAGE
compose config --quiet
if [[ "$DEPLOY_EASYNETTOPO_IMAGE" == easynettopo:local ]]; then
    docker image inspect "$DEPLOY_EASYNETTOPO_IMAGE" >/dev/null || fail "请先从 EasyNetTopo 源码构建 easynettopo:local"
else
    compose pull
fi
# --remove-orphans 清理旧版同项目 Caddy 网关；上方 verify_ownership 已限定允许的容器名和归属。
compose up -d --remove-orphans --pull never --wait --wait-timeout 180
bootstrap_admin
echo "EasyNetTopo 已就绪：http://127.0.0.1:$EASYNETTOPO_HTTP_PORT"
echo "宿主机监听：$EASYNETTOPO_BIND_IP:$EASYNETTOPO_HTTP_PORT"
if [[ "$EASYNETTOPO_BIND_IP" == 0.0.0.0 ]]; then
    echo "提示：可通过服务器 IPv4 地址访问；请使用防火墙限制来源，公网使用 HTTPS。"
fi
