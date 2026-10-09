#!/bin/sh
set -eu

# Cloud Core uses its OWN Web Config Server; network instances are Web-managed.
CLOUD_CONFIG_DIR="${EASYTIER_CLOUD_MANAGED_CONFIG_DIR:-/cloud-managed-core}"
WEB_DATA_DIR="${EASYTIER_WEB_DATA_DIR:-/data}"
MACHINE_ID_FILE="${EASYTIER_MACHINE_ID_FILE:-/etc/machine-id}"

: "${EASYTIER_RPC_PORT:?EASYTIER_RPC_PORT 未设置}"
: "${EASYTIER_WEB_PORT:?EASYTIER_WEB_PORT 未设置}"
: "${EASYTIER_CONFIG_PORT:?EASYTIER_CONFIG_PORT 未设置}"
: "${EASYTIER_WEB_API_HOST:?EASYTIER_WEB_API_HOST 未设置}"

[ -s "$MACHINE_ID_FILE" ] || {
    echo "machine-id 不存在或为空: $MACHINE_ID_FILE" >&2
    exit 1
}
mkdir -p "$CLOUD_CONFIG_DIR" "$WEB_DATA_DIR"

MACHINE_ID="$(tr -cd 'A-Za-z0-9._-' < "$MACHINE_ID_FILE")"
[ -n "$MACHINE_ID" ] || {
    echo "无法读取有效 machine-id" >&2
    exit 1
}
CLOUD_CONFIG_SERVER="udp://127.0.0.1:${EASYTIER_CONFIG_PORT}/admin"
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

echo "[EasyTier] role=cloud (Web-managed Core)"
echo "[EasyTier] Web: $EASYTIER_WEB_API_HOST"
echo "[EasyTier] Core Config Server: $CLOUD_CONFIG_SERVER"
echo "[EasyTier] Core managed config: $CLOUD_CONFIG_DIR"
echo "[EasyTier] IMPORTANT: set cloud Core listeners and disable_relay_data=true in Web."
echo "[EasyTier] IMPORTANT: Web now controls relay flags; they are NOT statically locked."

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

# Deliberately do not load the old standalone cloud.toml or connect to an
# external server. A separate config-dir avoids duplicate legacy instances.
easytier-core \
    --config-server "$CLOUD_CONFIG_SERVER" \
    --config-dir "$CLOUD_CONFIG_DIR" \
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
        echo "EasyTier Web Console 已退出，触发 Docker 重启" >&2
        exit 1
    fi
    if ! kill -0 "$CORE_PID" 2>/dev/null; then
        wait "$CORE_PID" || true
        echo "EasyTier cloud Core 已退出，触发 Docker 重启" >&2
        exit 1
    fi
    sleep 2
done
