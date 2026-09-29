#!/bin/sh
set -eu

CORE_CONFIG_DIR="${EASYTIER_CORE_CONFIG_DIR:-/config}"
MACHINE_ID_FILE="${EASYTIER_MACHINE_ID_FILE:-/etc/machine-id}"

: "${EASYTIER_PORT:?EASYTIER_PORT 未设置}"
: "${EASYTIER_RPC_PORT:?EASYTIER_RPC_PORT 未设置}"
: "${EASYTIER_CONFIG_SERVER:?内网模式必须设置 EASYTIER_CONFIG_SERVER，例如 udp://公网服务器IP:7008/admin}"

case "$EASYTIER_CONFIG_SERVER" in
    udp://*|tcp://*) ;;
    *)
        echo "EASYTIER_CONFIG_SERVER 必须以 udp:// 或 tcp:// 开头" >&2
        exit 1
        ;;
esac

[ -s "$MACHINE_ID_FILE" ] || {
    echo "machine-id 不存在或为空: $MACHINE_ID_FILE" >&2
    exit 1
}

mkdir -p "$CORE_CONFIG_DIR"
MACHINE_ID="$(tr -cd 'A-Za-z0-9._-' < "$MACHINE_ID_FILE")"
[ -n "$MACHINE_ID" ] || {
    echo "无法读取有效 machine-id" >&2
    exit 1
}

echo "[EasyTier] role=intranet"
echo "[EasyTier] Listener: TCP/UDP ${EASYTIER_PORT}"
echo "[EasyTier] RPC:      127.0.0.1:${EASYTIER_RPC_PORT}"
echo "[EasyTier] Config:   ${EASYTIER_CONFIG_SERVER}"

exec easytier-core \
    --config-server "$EASYTIER_CONFIG_SERVER" \
    --config-dir "$CORE_CONFIG_DIR" \
    --machine-id "$MACHINE_ID" \
    --listeners "tcp://0.0.0.0:${EASYTIER_PORT},udp://0.0.0.0:${EASYTIER_PORT}" \
    --rpc-portal "$EASYTIER_RPC_PORT"
