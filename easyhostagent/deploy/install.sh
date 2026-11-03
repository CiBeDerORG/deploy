#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

agent_fail() { printf 'EasyHostAgent：%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || agent_fail "需要 root 权限运行 Docker 部署"
mode="${1:-install}"
case "$mode" in install|update) ;; *) agent_fail "仅支持 install/update" ;; esac

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$MODULE/.." && pwd)"
source "$HERE/config.sh"

# 只从统一配置读取参数，禁止外部环境覆盖已保存的设置。
unset EASYHOSTAGENT_IMAGE EASYHOSTAGENT_RELEASE EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS
unset EASYHOSTAGENT_LOG_LEVEL EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_APP_GRANTS
agent_load_env "$SOFTWARE_ROOT/deploy/.env"
agent_validate_env

# 先检查原生服务；不自动卸载或覆盖旧 systemd 实例与身份。
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet easyhostagent.service || systemctl is-enabled --quiet easyhostagent.service; then
        agent_fail "原生 easyhostagent.service 仍在运行或开机启动；切换 Docker 前请自行执行 sudo systemctl disable --now easyhostagent.service，原数据目录会保留"
    fi
fi

command -v flock >/dev/null || agent_fail "缺少 flock"
docker compose version >/dev/null || agent_fail "需要 Docker Compose v2"
docker info >/dev/null || agent_fail "Docker Engine 不可用"
[[ -S /var/run/docker.sock ]] || agent_fail "需要可访问的宿主机 /var/run/docker.sock"
mkdir -p -- "$SOFTWARE_ROOT/deploy/state"
exec 8>"$SOFTWARE_ROOT/deploy/state/easyhostagent.lock"
flock -n 8 || agent_fail "已有 EasyHostAgent 部署操作正在执行"

# 保持容器中的应用路径与宿主机完全相同，确保脚本传给宿主机 Docker 的挂载路径正确。
export DEPLOY_EASYHOSTAGENT_SOFTWARE_ROOT="$EASYHOSTAGENT_SOFTWARE_ROOT"
export DEPLOY_EASYHOSTAGENT_DATA_DIR="$EASYHOSTAGENT_DATA_DIR"
export DEPLOY_EASYHOSTAGENT_BIND_IP="${EASYHOSTAGENT_LISTEN_ADDRESS%:*}"
export DEPLOY_EASYHOSTAGENT_PORT="${EASYHOSTAGENT_LISTEN_ADDRESS##*:}"
export DEPLOY_EASYHOSTAGENT_IMAGE="$EASYHOSTAGENT_IMAGE"
export EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_APP_GRANTS EASYHOSTAGENT_LOG_LEVEL
export TZ="${TZ:-Asia/Shanghai}"
export DEPLOY_EASYHOSTAGENT_PLATFORM=linux
if [[ -f /etc/fnos-release ]] || { [[ -r /etc/os-release ]] && grep -Eqi '^(ID|ID_LIKE|NAME)=.*fnos' /etc/os-release; }; then
    DEPLOY_EASYHOSTAGENT_PLATFORM=fnos
fi
export DEPLOY_EASYHOSTAGENT_PLATFORM

if [[ "$EASYHOSTAGENT_DATA_DIR" == "$EASYHOSTAGENT_SOFTWARE_ROOT"/* ]] ||
   [[ "$EASYHOSTAGENT_SOFTWARE_ROOT" == "$EASYHOSTAGENT_DATA_DIR"/* ]]; then
    agent_fail "数据目录和软件根目录不能互相包含"
fi
# 数据目录包含 Agent UUID、身份私钥、Token 摘要，默认拒绝接管权限不安全的已有目录。
if [[ -L "$EASYHOSTAGENT_DATA_DIR" ]]; then
    agent_fail "数据目录不能是符号链接"
fi
if [[ ! -e "$EASYHOSTAGENT_DATA_DIR" ]]; then
    mkdir -m 0700 -p -- "$EASYHOSTAGENT_DATA_DIR"
fi
[[ -d "$EASYHOSTAGENT_DATA_DIR" ]] || agent_fail "Agent 数据目录不可用"
[[ "$(stat -c '%u:%a' "$EASYHOSTAGENT_DATA_DIR")" == "0:700" ]] ||
    agent_fail "Agent 数据目录必须由 root 拥有且权限为 0700；不会修改已有目录权限"
[[ -d "$EASYHOSTAGENT_SOFTWARE_ROOT" && ! -L "$EASYHOSTAGENT_SOFTWARE_ROOT" ]] ||
    agent_fail "软件根目录不存在或为符号链接"

compose() {
    docker compose --env-file /dev/null --project-name easyhostagent --project-directory "$HERE" -f "$HERE/docker-compose.yaml" "$@"
}
# 不允许覆盖其他项目创建的同名 Docker 容器。
owned="$(docker ps -a --filter label=com.docker.compose.project=easyhostagent --format '{{.Names}}')"
while IFS= read -r name; do
    case "$name" in ""|easyhostagent) ;; *) agent_fail "Compose 项目存在不属于本部署的附加容器" ;; esac
done <<< "$owned"
if docker container inspect easyhostagent >/dev/null 2>&1; then
    grep -Fxq easyhostagent <<< "$owned" || agent_fail "同名容器不属于本项目"
    service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' easyhostagent)"
    directory="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' easyhostagent)"
    [[ "$service" == easyhostagent && "$directory" == "$HERE" ]] ||
        agent_fail "同名容器来自其他服务或部署目录"
fi
if [[ "$mode" == update ]] && ! docker container inspect easyhostagent >/dev/null 2>&1; then
    agent_fail "尚未安装 EasyHostAgent Docker 容器，请先执行 install"
fi

source "$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
deploy_prepare_images "$SOFTWARE_ROOT" "$SOFTWARE_ROOT/deploy/.env" DEPLOY_EASYHOSTAGENT_IMAGE
compose config --quiet
compose pull
compose up -d --pull never --wait --wait-timeout 180

echo "EasyHostAgent Docker 已就绪：$EASYHOSTAGENT_TRANSPORT://127.0.0.1:$DEPLOY_EASYHOSTAGENT_PORT/v1/health"
echo "宿主机监听：$EASYHOSTAGENT_LISTEN_ADDRESS；Agent 数据：$EASYHOSTAGENT_DATA_DIR"
if [[ "$EASYHOSTAGENT_TRANSPORT" == http ]]; then
    echo "HTTP 模式仅建议用于可信隔离网络；Docker Socket 赋予容器宿主机级管理权限，请限制 7018 端口的访问来源。"
fi
