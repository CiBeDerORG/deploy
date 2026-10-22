#!/usr/bin/env bash
# Entrypoint for deploy-mihomo.service. Secrets are read at run time, never
# copied into a world-readable systemd unit or command arguments.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
ROOT="$(cd -- "$MODULE/.." && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"
load_settings "$ROOT"
current="$MODULE/runtime/host/current"
node="$MODULE/runtime/host/node-current/bin/node"
[ -f "$current/server/index.mjs" ] && [ -f "$current/ui-dist/index.html" ] ||
    die "宿主机 Web/Agent 安装文件不完整，请重新安装"
[ -x "$node" ] && [ -x "$current/mihomo" ] || die "宿主机 Node/Mihomo 内核缺失"

export NODE_ENV=production
export DATA_DIR="$MODULE/data/all-in-one"
export UI_DIST="$current/ui-dist"
export MIHOMO_REAL_BIN="$current/mihomo"
export MIHOMO_BIN="$HERE/host-kernel.sh"
export MIHOMO_KERNEL_TMPDIR=/run/deploy-mihomo
export CONTROL_TOKEN="\${MIHOMO_CONTROL_TOKEN:?MIHOMO_CONTROL_TOKEN missing}"
export CLASH_SECRET="\${MIHOMO_API_SECRET:?MIHOMO_API_SECRET missing}"
export CONTROL_PORT="\${MIHOMO_API_PORT:-7012}"
export CLASH_API_PORT="\${MIHOMO_CORE_API_PORT:-7013}"
export MIXED_PORT="\${MIHOMO_MIXED_PORT:-7011}"
export MIHOMO_PROXY_BIND_IP="\${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
export MIHOMO_CORE_API_BIND_IP="\${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
export MIHOMO_MIXED_PORT="$MIXED_PORT"
export MIHOMO_CORE_API_PORT="$CLASH_API_PORT"
export NITRO_HOST="\${MIHOMO_API_BIND_IP:-0.0.0.0}"
export PORT="$CONTROL_PORT"
export TZ="\${TZ:-Asia/Shanghai}"
exec "$node" "$current/server/index.mjs"
