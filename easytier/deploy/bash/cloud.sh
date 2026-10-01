#!/bin/sh
set -eu

WEB_DATA_DIR="${EASYTIER_WEB_DATA_DIR:-/data}"

: "${EASYTIER_WEB_PORT:?EASYTIER_WEB_PORT 未设置}"
: "${EASYTIER_CONFIG_PORT:?EASYTIER_CONFIG_PORT 未设置}"
: "${EASYTIER_WEB_API_HOST:?EASYTIER_WEB_API_HOST 未设置}"

mkdir -p "$WEB_DATA_DIR"

echo "[EasyTier] role=cloud"
echo "[EasyTier] mode: management-only"
echo "[EasyTier] Web:      ${EASYTIER_WEB_API_HOST}"
echo "[EasyTier] Config:   udp://0.0.0.0:${EASYTIER_CONFIG_PORT}/admin"
echo "[EasyTier] Core:     disabled"
echo "[EasyTier] Relay:    disabled (no cloud core)"

exec easytier-web-embed \
    --api-server-addr 0.0.0.0 \
    --api-server-port "$EASYTIER_WEB_PORT" \
    --api-host "$EASYTIER_WEB_API_HOST" \
    --config-server-port "$EASYTIER_CONFIG_PORT" \
    --config-server-protocol udp \
    --db "$WEB_DATA_DIR/et.db"
