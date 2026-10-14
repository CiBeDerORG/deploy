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
MIHOMO_MIXED_PORT="${MIHOMO_MIXED_PORT:-7011}"
MIHOMO_API_PORT="${MIHOMO_API_PORT:-7012}"
MIHOMO_PROXY_BIND_IP="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
MIHOMO_API_BIND_IP="${MIHOMO_API_BIND_IP:-0.0.0.0}"
validate_port MIHOMO_MIXED_PORT "$MIHOMO_MIXED_PORT"
validate_port MIHOMO_API_PORT "$MIHOMO_API_PORT"
[ "$MIHOMO_MIXED_PORT" != "$MIHOMO_API_PORT" ] || fail "Mihomo 代理和 API 端口不能相同"
validate_ipv4 MIHOMO_PROXY_BIND_IP "$MIHOMO_PROXY_BIND_IP"
validate_ipv4 MIHOMO_API_BIND_IP "$MIHOMO_API_BIND_IP"
ensure_hex_secret MIHOMO_API_SECRET
# User-provided API credentials are never restricted by deploy-only policies.
# Leaving the field blank still requests a strong generated secret.
MIHOMO_PROXY_USER="${MIHOMO_PROXY_USER:-deploy}"
[[ "$MIHOMO_PROXY_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "MIHOMO_PROXY_USER 只允许字母数字 _ . -"
ensure_hex_secret MIHOMO_PROXY_PASSWORD
# Mihomo does not require hex-only proxy passwords. Preserve user input.
export MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_API_SECRET
verify_container_owner mihomo mihomo
if [ "$MODE" = update ]; then
    docker container inspect mihomo >/dev/null 2>&1 || fail "未找到 Mihomo 容器，请先安装"
    [ -f "$BASE_DIR/data/config.yaml" ] || fail "配置文件丢失，请先恢复数据，拒绝覆盖"
fi
install -d -m 0700 "$BASE_DIR/data"
if [ ! -f "$BASE_DIR/data/config.yaml" ]; then
    [ "$MODE" = install ] || fail "更新模式不会重新生成配置"
    cp "$DEPLOY_DIR/config.example.yaml" "$BASE_DIR/data/config.yaml"
    # Losslessly quote user credentials as a YAML single-quoted scalar.
    auth_entry="$(yaml_single_quote_scalar "$MIHOMO_PROXY_USER:$MIHOMO_PROXY_PASSWORD")"
    cat >> "$BASE_DIR/data/config.yaml" <<EOF_AUTH

# 首次代理认证凭据来自 .secrets；此后可编辑 data/config.yaml 手动轮换。
authentication:
  - $auth_entry
EOF_AUTH
    chmod 0600 "$BASE_DIR/data/config.yaml"
    echo "已生成首次配置：$BASE_DIR/data/config.yaml（更新不会覆盖）"
fi
# Create/check the opt-in internal network before Compose evaluates its external reference.
bash "$DEPLOY_DIR/proxy-network.sh" ensure
cd "$DEPLOY_DIR"
compose() { docker compose -f "$DEPLOY_DIR/docker-compose.yaml" "$@"; }
compose config --quiet || fail "Compose 配置校验失败"
compose pull
# Mihomo CLI uses the same mounted config, so reject invalid config before replacing a running container.
compose run --rm --no-deps mihomo -t -d /root/.config/mihomo -f /root/.config/mihomo/config.yaml || fail "Mihomo 配置校验失败"
compose up -d --force-recreate || { compose logs --tail=80 || true; fail "启动失败"; }
state="$(docker inspect --format '{{.State.Status}}' mihomo 2>/dev/null || true)"
[ "$state" = running ] || { compose logs --tail=80 || true; fail "容器状态：$state"; }
echo "Mihomo 已启动，混合代理：$MIHOMO_PROXY_BIND_IP:$MIHOMO_MIXED_PORT；控制接口：$MIHOMO_API_BIND_IP:$MIHOMO_API_PORT"
if [ "$MIHOMO_API_BIND_IP" = "0.0.0.0" ]; then
    echo "Web 管理入口：http://<NAS局域网IP>:$MIHOMO_API_PORT/ui/"
    echo "Web 面板对 NAS 可达的 IPv4 网络开放；7012 同时承载控制 API，操作需要 MIHOMO_API_SECRET。"
    echo "如 NAS 可从公网到达，请确保 API 密钥保密，并按需限制公网访问。"
elif [ "$MIHOMO_API_BIND_IP" = "127.0.0.1" ]; then
    echo "Web 管理入口（仅宿主机）：http://127.0.0.1:$MIHOMO_API_PORT/ui/"
    echo "若需要其他设备直接打开 Web 页面，把统一 .env 的 MIHOMO_API_BIND_IP 改为 0.0.0.0，再运行 mihomo update。"
else
    echo "Web 管理入口：http://$MIHOMO_API_BIND_IP:$MIHOMO_API_PORT/ui/"
    echo "提示：绑定 NAS 局域网 IP 并不限制客户端来源，仍需 NAS 防火墙允许名单。"
fi
echo "若面板提示连接核心：API 地址为上述入口去掉 /ui/，密钥在 $SECRETS_FILE 的 MIHOMO_API_SECRET 中。"
echo "配置路径：$BASE_DIR/data/config.yaml；默认未启用 TUN/host 网络。"
echo "Mihomo 已通过 Compose 接入内部网络 proxy-net；其他容器可用 deploy.sh proxy connect/disconnect/status 管理。"
compose ps
