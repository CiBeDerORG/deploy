#!/usr/bin/env bash
# Each release owns its launcher, helpers, Node and core. Repository syncs must
# never change a running release or the version selected for rollback.
set -Eeuo pipefail
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
HERE="$(dirname -- "$SELF")"
# Keep old units bootable even if syncing is followed by an early build error.
if [ "$#" -eq 0 ] && [ "$(basename -- "$HERE")" = deploy ]; then
    module="$(cd -- "$HERE/.." && pwd -P)"
    launcher="$module/runtime/host/current/launch/host-run.sh"
    if [ -f "$launcher" ]; then exec /bin/bash "$launcher" "$module"; fi
    exec /bin/bash "$HERE/host-legacy-run.sh" "$module"
fi
[ "$#" -eq 1 ] && [[ "$1" = /* ]] || {
    echo "Usage: host-run.sh ABSOLUTE_MIHOMO_DIRECTORY" >&2; exit 2;
}
MODULE="$(cd -- "$1" && pwd -P)"
ROOT="$(dirname -- "$MODULE")"
RELEASE="$(cd -- "$HERE/.." && pwd -P)"
[ "$(basename -- "$HERE")" = launch ] || {
    echo "Native launcher must run from a complete release" >&2; exit 1;
}
# shellcheck source=./common.sh
source "$HERE/common.sh"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Running}}' mihomo 2>/dev/null || :)" != true ] ||
        die "Docker mihomo 已运行，拒绝同时启动原生 Agent（共享 data/all-in-one）"
fi
load_settings "$ROOT"
for key in MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT; do
    case "$key" in
        MIHOMO_MIXED_PORT) value="${!key:-7011}" ;;
        MIHOMO_API_PORT) value="${!key:-7012}" ;;
        MIHOMO_CORE_API_PORT) value="${!key:-7013}" ;;
    esac
    check_port "$key" "$value"
    printf -v "$key" '%d' "$((10#$value))"
    export "$key"
done
(( MIHOMO_MIXED_PORT != MIHOMO_API_PORT &&
   MIHOMO_MIXED_PORT != MIHOMO_CORE_API_PORT &&
   MIHOMO_API_PORT != MIHOMO_CORE_API_PORT )) || die "Mihomo 三个监听端口不能冲突"
export MIHOMO_PROXY_BIND_IP="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
export MIHOMO_CORE_API_BIND_IP="${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
MIHOMO_API_BIND_IP="${MIHOMO_API_BIND_IP:-0.0.0.0}"
for key in MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP; do
    check_ipv4 "$key" "${!key}"
done
case "$MIHOMO_CORE_API_BIND_IP" in
    0.0.0.0|127.0.0.1) ;;
    *) die "宿主机内核 API 监听地址需为 0.0.0.0 或 127.0.0.1，以供 Agent 探活" ;;
esac
export MIHOMO_NODE_BIN="$RELEASE/node/bin/node"
export MIHOMO_REAL_BIN="$RELEASE/mihomo"
[ -x "$MIHOMO_NODE_BIN" ] && [ -x "$MIHOMO_REAL_BIN" ] &&
    [ -f "$RELEASE/server/index.mjs" ] && [ -f "$RELEASE/ui-dist/index.html" ] &&
    [ -f "$HERE/host-config.mjs" ] && [ -f "$RELEASE/node_modules/yaml/package.json" ] ||
    die "宿主机发布文件不完整，请重新安装"
umask 077
export TMPDIR="$MODULE/runtime/host/tmp"
export MIHOMO_KERNEL_TMPDIR="$TMPDIR/kernel"
mkdir -p "$MIHOMO_KERNEL_TMPDIR"
chmod 0700 "$TMPDIR" "$MIHOMO_KERNEL_TMPDIR"
export NODE_ENV=production
export DATA_DIR="$MODULE/data/all-in-one"
export UI_DIST="$RELEASE/ui-dist"
export MIHOMO_BIN="$HERE/host-kernel.sh"
export CONTROL_TOKEN="${MIHOMO_CONTROL_TOKEN:?MIHOMO_CONTROL_TOKEN missing}"
export CLASH_SECRET="${MIHOMO_API_SECRET:?MIHOMO_API_SECRET missing}"
export CONTROL_PORT="$MIHOMO_API_PORT"
export CLASH_API_PORT="$MIHOMO_CORE_API_PORT"
export MIXED_PORT="$MIHOMO_MIXED_PORT"
export NITRO_HOST="$MIHOMO_API_BIND_IP"
export PORT="$CONTROL_PORT"
export TZ="${TZ:-Asia/Shanghai}"
exec "$MIHOMO_NODE_BIN" "$RELEASE/server/index.mjs"
