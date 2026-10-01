#!/bin/sh
set -eu

CORE_CONFIG_DIR="${EASYTIER_CORE_CONFIG_DIR:-/config}"
CLOUD_CONFIG_DIR="${EASYTIER_CLOUD_CONFIG_DIR:-/cloud-core}"
WEB_DATA_DIR="${EASYTIER_WEB_DATA_DIR:-/data}"
MACHINE_ID_FILE="${EASYTIER_MACHINE_ID_FILE:-/etc/machine-id}"
CLOUD_CONFIG_FILE="$CLOUD_CONFIG_DIR/cloud.toml"

: "${EASYTIER_PORT:?EASYTIER_PORT 未设置}"
: "${EASYTIER_RPC_PORT:?EASYTIER_RPC_PORT 未设置}"
: "${EASYTIER_WEB_PORT:?EASYTIER_WEB_PORT 未设置}"
: "${EASYTIER_CONFIG_PORT:?EASYTIER_CONFIG_PORT 未设置}"
: "${EASYTIER_WEB_API_HOST:?EASYTIER_WEB_API_HOST 未设置}"

[ -s "$MACHINE_ID_FILE" ] || {
    echo "machine-id 不存在或为空: $MACHINE_ID_FILE" >&2
    exit 1
}

mkdir -p "$CORE_CONFIG_DIR" "$CLOUD_CONFIG_DIR" "$WEB_DATA_DIR"

toml_read_string() {
    key="$1"
    file="$2"
    sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$file" | head -n 1
}

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

find_legacy_config() {
    for file in "$CORE_CONFIG_DIR"/*.toml; do
        [ -f "$file" ] || continue
        if [ -n "$(toml_read_string network_name "$file")" ]; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}

prepare_cloud_config() {
    if [ -s "$CLOUD_CONFIG_FILE" ]; then
        return 0
    fi

    network_name="${EASYTIER_CLOUD_NETWORK_NAME:-}"
    network_secret="${EASYTIER_CLOUD_NETWORK_SECRET:-}"
    cloud_ipv4="${EASYTIER_CLOUD_IPV4:-}"
    source_file=""

    if [ -z "$network_name" ] || [ -z "$network_secret" ] || [ -z "$cloud_ipv4" ]; then
        source_file="$(find_legacy_config || true)"
    fi

    if [ -z "$network_name" ] && [ -n "$source_file" ]; then
        network_name="$(toml_read_string network_name "$source_file")"
    fi

    if [ -z "$network_secret" ] && [ -n "$source_file" ]; then
        network_secret="$(toml_read_string network_secret "$source_file")"
    fi

    if [ -z "$cloud_ipv4" ] && [ -n "$source_file" ]; then
        cloud_ipv4="$(toml_read_string ipv4 "$source_file")"
    fi

    [ -n "$network_name" ] || {
        echo "无法确定 cloud Core 的 network_name。" >&2
        echo "请在 .env 设置 EASYTIER_CLOUD_NETWORK_NAME，或保留旧 data/core/*.toml 供自动迁移。" >&2
        exit 1
    }

    [ -n "$network_secret" ] || {
        echo "无法确定 cloud Core 的 network_secret。" >&2
        echo "请在 .secrets 设置 EASYTIER_CLOUD_NETWORK_SECRET。为保证 Private Mode，不允许空密钥。" >&2
        exit 1
    }

    if [ -z "$cloud_ipv4" ]; then
        cloud_ipv4="10.10.10.1/24"
    fi

    network_name_escaped="$(toml_escape "$network_name")"
    network_secret_escaped="$(toml_escape "$network_secret")"
    cloud_ipv4_escaped="$(toml_escape "$cloud_ipv4")"

    tmp="$CLOUD_CONFIG_FILE.tmp"
    cat > "$tmp" <<EOF
instance_name = "cloud-p2p-coordinator"
ipv4 = "$cloud_ipv4_escaped"
dhcp = false
listeners = [
    "tcp://0.0.0.0:${EASYTIER_PORT}",
    "udp://0.0.0.0:${EASYTIER_PORT}",
]
exit_nodes = []
proxy_network = []

[network_identity]
network_name = "$network_name_escaped"
network_secret = "$network_secret_escaped"

[flags]
enable_exit_node = false
no_tun = false
private_mode = true
relay_all_peer_rpc = true
relay_network_whitelist = ""
disable_relay_data = true
disable_p2p = false
disable_tcp_hole_punching = false
disable_udp_hole_punching = false
disable_sym_hole_punching = false
disable_upnp = true
enable_udp_broadcast_relay = false
EOF

    chmod 0600 "$tmp"
    mv "$tmp" "$CLOUD_CONFIG_FILE"

    if [ -n "$source_file" ]; then
        echo "[EasyTier] 已从旧 Core 配置迁移 cloud 网络身份: $source_file"
    else
        echo "[EasyTier] 已从 .env/.secrets 生成 cloud Core 安全配置"
    fi
}

prepare_cloud_config

MACHINE_ID="$(tr -cd 'A-Za-z0-9._-' < "$MACHINE_ID_FILE")"
[ -n "$MACHINE_ID" ] || {
    echo "无法读取有效 machine-id" >&2
    exit 1
}

WEB_PID=""
CORE_PID=""

cleanup() {
    trap - INT TERM EXIT

    [ -n "$CORE_PID" ] && kill "$CORE_PID" 2>/dev/null || true
    [ -n "$WEB_PID" ] && kill "$WEB_PID" 2>/dev/null || true

    [ -n "$CORE_PID" ] && wait "$CORE_PID" 2>/dev/null || true
    [ -n "$WEB_PID" ] && wait "$WEB_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

echo "[EasyTier] role=cloud"
echo "[EasyTier] mode: p2p-coordinator"
echo "[EasyTier] Listener: TCP/UDP ${EASYTIER_PORT}"
echo "[EasyTier] RPC:      127.0.0.1:${EASYTIER_RPC_PORT}"
echo "[EasyTier] Web:      ${EASYTIER_WEB_API_HOST}"
echo "[EasyTier] Config:   udp://0.0.0.0:${EASYTIER_CONFIG_PORT}/admin"
echo "[EasyTier] Core cfg: ${CLOUD_CONFIG_FILE}"
echo "[EasyTier] Relay:    disabled"
echo "[EasyTier] ExitNode: disabled"
echo "[EasyTier] Peer RPC: enabled for P2P coordination"

easytier-web-embed \
    --api-server-addr 0.0.0.0 \
    --api-server-port "$EASYTIER_WEB_PORT" \
    --api-host "$EASYTIER_WEB_API_HOST" \
    --config-server-port "$EASYTIER_CONFIG_PORT" \
    --config-server-protocol udp \
    --db "$WEB_DATA_DIR/et.db" &
WEB_PID=$!

sleep 1
if ! kill -0 "$WEB_PID" 2>/dev/null; then
    wait "$WEB_PID" || true
    echo "EasyTier Web Console 启动失败" >&2
    exit 1
fi

# cloud Core 使用独立、静态的安全配置。
# 故意不连接 Web Config Server，避免 Web 下发配置重新打开 Relay / Exit Node。
easytier-core \
    --config-file "$CLOUD_CONFIG_FILE" \
    --machine-id "$MACHINE_ID" \
    --rpc-portal "$EASYTIER_RPC_PORT" &
CORE_PID=$!

sleep 1
if ! kill -0 "$CORE_PID" 2>/dev/null; then
    wait "$CORE_PID" || true
    echo "EasyTier cloud Core 启动失败" >&2
    exit 1
fi

while :; do
    if ! kill -0 "$WEB_PID" 2>/dev/null; then
        wait "$WEB_PID" || true
        echo "EasyTier Web Console 已退出，结束容器以触发 Docker 重启" >&2
        exit 1
    fi

    if ! kill -0 "$CORE_PID" 2>/dev/null; then
        wait "$CORE_PID" || true
        echo "EasyTier cloud Core 已退出，结束容器以触发 Docker 重启" >&2
        exit 1
    fi

    sleep 2
done
