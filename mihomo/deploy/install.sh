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
MIHOMO_API_BIND_IP="${MIHOMO_API_BIND_IP:-127.0.0.1}"
validate_port MIHOMO_MIXED_PORT "$MIHOMO_MIXED_PORT"
validate_port MIHOMO_API_PORT "$MIHOMO_API_PORT"
[ "$MIHOMO_MIXED_PORT" != "$MIHOMO_API_PORT" ] || fail "Mihomo 代理和 API 端口不能相同"
validate_ipv4 MIHOMO_PROXY_BIND_IP "$MIHOMO_PROXY_BIND_IP"
validate_ipv4 MIHOMO_API_BIND_IP "$MIHOMO_API_BIND_IP"
ensure_hex_secret MIHOMO_API_SECRET
# A LAN-accessible Web panel also exposes the controller API. Require a strong key.
if [ "$MIHOMO_API_BIND_IP" != 127.0.0.1 ] && [ "${#MIHOMO_API_SECRET}" -lt 32 ]; then
    fail "Web 控制接口允许远程访问时，MIHOMO_API_SECRET 至少需要 32 个字符（推荐留空自动生成）。"
fi
MIHOMO_PROXY_USER="${MIHOMO_PROXY_USER:-deploy}"
[[ "$MIHOMO_PROXY_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "MIHOMO_PROXY_USER 只允许字母数字 _ . -"
ensure_hex_secret MIHOMO_PROXY_PASSWORD
[[ "$MIHOMO_PROXY_PASSWORD" =~ ^[A-Fa-f0-9]+$ ]] || fail "MIHOMO_PROXY_PASSWORD 应为 hex 字符（首次安装会自动生成）"
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
    # Credential charset is restricted, so it can safely be emitted as a YAML quoted scalar.
    cat >> "$BASE_DIR/data/config.yaml" <<EOF_AUTH

# 首次代理认证凭据来自 .secrets；此后可编辑 data/config.yaml 手动轮换。
authentication:
  - "$MIHOMO_PROXY_USER:$MIHOMO_PROXY_PASSWORD"
EOF_AUTH
    chmod 0600 "$BASE_DIR/data/config.yaml"
    echo "已生成首次配置：$BASE_DIR/data/config.yaml（更新不会覆盖）"
fi
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
    echo "警告：7012 控制 API 监听全部 IPv4 网卡！建议将 MIHOMO_API_BIND_IP 改成 NAS 指定的局域网 IP。"
    echo "请在 NAS 防火墙仅放行可信管理设备/IP，严禁公网端口映射。"
elif [ "$MIHOMO_API_BIND_IP" = "127.0.0.1" ]; then
    echo "Web 管理入口（仅宿主机）：http://127.0.0.1:$MIHOMO_API_PORT/ui/"
    echo "需要从电脑访问 NAS Web 管理时，在统一 .env 将 MIHOMO_API_BIND_IP 改为 NAS 局域网 IP，再运行 mihomo update。"
else
    echo "Web 管理入口：http://$MIHOMO_API_BIND_IP:$MIHOMO_API_PORT/ui/"
    echo "提示：绑定 NAS 局域网 IP 并不限制客户端来源，仍需 NAS 防火墙允许名单。"
fi
echo "若面板提示连接核心：API 地址为上述入口去掉 /ui/，密钥在 $SECRETS_FILE 的 MIHOMO_API_SECRET 中。"
echo "配置路径：$BASE_DIR/data/config.yaml；默认未启用 TUN/host 网络。"
compose ps
