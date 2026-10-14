#!/usr/bin/env bash
# Fresh MetaCubeXD All-in-One installer. Legacy files are migration inputs only.
set -Eeuo pipefail
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) printf '用法：install.sh [install|update]\n' >&2; exit 2 ;; esac
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
ROOT="$(cd -- "$MODULE/.." && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"
# shellcheck source=./migrate.sh
source "$HERE/migrate.sh"
must_be_root
docker_ready
load_settings "$ROOT"

MIHOMO_MIXED_PORT="${MIHOMO_MIXED_PORT:-7011}"
MIHOMO_API_PORT="${MIHOMO_API_PORT:-7012}"         # Backwards-compatible name: Web/Agent
MIHOMO_CORE_API_PORT="${MIHOMO_CORE_API_PORT:-7013}"
MIHOMO_PROXY_BIND_IP="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
MIHOMO_API_BIND_IP="${MIHOMO_API_BIND_IP:-0.0.0.0}"
MIHOMO_CORE_API_BIND_IP="${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
MIHOMO_PROXY_USER="${MIHOMO_PROXY_USER:-deploy}"
MIHOMO_WEB_ORIGIN="${MIHOMO_WEB_ORIGIN:-}"
TZ="${TZ:-Asia/Shanghai}"

for key in MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT; do
    check_port "$key" "${!key}"
done
(( 10#$MIHOMO_MIXED_PORT != 10#$MIHOMO_API_PORT &&
   10#$MIHOMO_MIXED_PORT != 10#$MIHOMO_CORE_API_PORT &&
   10#$MIHOMO_API_PORT != 10#$MIHOMO_CORE_API_PORT )) ||
    die "7011 代理、7012 Web 和 7013 内核 API 的宿主机端口不能冲突"
for key in MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP; do
    check_ipv4 "$key" "${!key}"
done
# Fail on invalid optional origin before any changes to the running container.
if [ -n "$MIHOMO_WEB_ORIGIN" ]; then
    [[ "$MIHOMO_WEB_ORIGIN" =~ ^https?://[^/?#[:space:]]+$ ]] ||
        die "MIHOMO_WEB_ORIGIN 必须是形如 http://10.10.10.2:7012 的来源，不能带路径"
fi

assert_our_container
if [ "$MODE" = update ]; then
    docker container inspect mihomo >/dev/null 2>&1 ||
        die "尚无已安装的 Mihomo 容器，请先运行 sudo bash deploy.sh mihomo"
fi
secret_when_blank MIHOMO_API_SECRET     # Existing configured value is left untouched.
secret_when_blank MIHOMO_CONTROL_TOKEN  # Separate official control-agent credential.
export MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT
export MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP
export MIHOMO_API_SECRET MIHOMO_CONTROL_TOKEN TZ

bash "$HERE/proxy-network.sh" ensure
cd "$HERE"
compose() { docker compose -f "$HERE/docker-compose.yaml" "$@"; }
compose config --quiet || die "Compose 配置校验失败"
# Download and inspect the complete official image while the old container stays up.
compose pull || die "无法拉取官方完整版镜像；旧容器没有被替换"
IMAGE=ghcr.io/metacubex/metacubexd-server:latest
docker run --rm --network none --entrypoint /bin/sh "$IMAGE" -ec \
    'test -x /usr/local/bin/mihomo && test -f /app/server/index.mjs && test -d /app/ui-dist' ||
    die "拉取的镜像缺少官方 Web、Agent 或内核；旧容器没有被替换"

# New installation: atomic first-time seeding. Existing full-version Profiles
# are never rewritten, even when user has edited/imported them in Web.
initialize_aio "$MODULE/data" "$HERE/default-profile.yaml" "$MIHOMO_API_PORT" "$MIHOMO_WEB_ORIGIN"

# Validate with exactly the image's bundled mihomo BEFORE replacing the container.
docker run --rm --entrypoint /usr/local/bin/mihomo \
    --mount "type=bind,source=$MODULE/data/all-in-one,target=/data" \
    "$IMAGE" -t -d /data -f /data/active.yaml >/dev/null 2>&1 ||
    die "已有配置未通过完整版内核验证，旧容器不受影响；请检查备份和 Profile"

echo "预检通过，开始切换同名 mihomo 容器（代理会短暂中断）..."
compose up -d --force-recreate --wait --wait-timeout 120 ||
    die "完整版 Web/Agent 健康检查失败，原始 config.yaml 保留；查看 docker logs mihomo"

# A healthy Web server alone does not prove the supervised kernel has started.
for attempt in $(seq 1 30); do
    if docker exec mihomo node -e \
        'fetch("http://127.0.0.1:9090/version",{headers:{Authorization:"Bearer "+process.env.CLASH_SECRET}}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' \
        >/dev/null 2>&1; then
        echo "Web/Agent 与内核均已验收。"
        echo "Web：http://<NAS-IP>:$MIHOMO_API_PORT/；内核 API：$MIHOMO_CORE_API_PORT；代理：$MIHOMO_PROXY_BIND_IP:$MIHOMO_MIXED_PORT"
        echo "Docker 共享代理保持 mihomo:7890；全部数据：$MODULE/data/all-in-one"
        echo "注意：官方 CONTROL_TOKEN 会送往浏览器，并不是网页登录保护；请限制 7012/7013 的来源。"
        compose ps
        exit 0
    fi
    sleep 1
done
die "Web 已启动但内核在等待窗口内未就绪；查看 docker logs mihomo，旧文件仍保留"
