#!/usr/bin/env bash
# Compatibility only for installations made before versioned launchers. New
# releases use host-run.sh + host-config.mjs. The same file can be snapshotted
# as an old release's launch/host-run.sh for a self-contained rollback.
set -Eeuo pipefail
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
HERE="$(dirname -- "$SELF")"
if [[ "${1:-}" = -* ]]; then
    : "${MIHOMO_REAL_BIN:?Missing legacy core}"
    args=("$@")
    index=-1
    for ((i=0; i < ${#args[@]}; i++)); do
        if [ "${args[i]}" = -f ] || [ "${args[i]}" = --config ]; then
            (( i + 1 < ${#args[@]} )) || exit 2
            index=$((i + 1)); break
        fi
    done
    if (( index < 0 )); then exec "$MIHOMO_REAL_BIN" "$@"; fi
    : "${MIHOMO_KERNEL_TMPDIR:?Missing legacy temporary directory}"
    umask 077
    mkdir -p "$MIHOMO_KERNEL_TMPDIR"
    tmp="$(mktemp "$MIHOMO_KERNEL_TMPDIR/active.XXXXXXXX.yaml")"
    proxy_ip="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
    [ "$proxy_ip" != 0.0.0.0 ] || proxy_ip='*'
    awk -v p="${MIHOMO_MIXED_PORT:-7011}" -v a="$proxy_ip" \
        -v c="${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}:${MIHOMO_CORE_API_PORT:-7013}" '
        BEGIN {
            print "external-controller: \"" c "\""
            print "mixed-port: " p
            print "allow-lan: true"
            print "bind-address: \"" a "\""
        }
        !/^(external-controller|mixed-port|allow-lan|bind-address):[[:space:]]*/ {print}
    ' "${args[index]}" > "$tmp"
    args[index]="$tmp"
    exec "$MIHOMO_REAL_BIN" "${args[@]}"
fi
[ "$#" -eq 1 ] && [[ "$1" = /* ]] || { echo "Legacy launcher needs MODULE" >&2; exit 2; }
MODULE="$(cd -- "$1" && pwd -P)"
ROOT="$(dirname -- "$MODULE")"
# shellcheck source=./common.sh
source "$HERE/common.sh"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Running}}' mihomo 2>/dev/null || :)" != true ] ||
        die "Docker mihomo 已运行，拒绝同时启动原生 Agent"
fi
load_settings "$ROOT"
if [ "$(basename -- "$HERE")" = launch ]; then
    release="$(cd -- "$HERE/.." && pwd -P)"
    node="$release/node/bin/node"
else
    release="$(readlink -f -- "$MODULE/runtime/host/current")"
    node="$(readlink -f -- "$MODULE/runtime/host/node-current")/bin/node"
fi
[ -x "$node" ] && [ -x "$release/mihomo" ] &&
    [ -f "$release/server/index.mjs" ] && [ -f "$release/ui-dist/index.html" ] ||
    die "旧版本发布文件不完整，请执行 mihomo host-update"
export NODE_ENV=production
export DATA_DIR="$MODULE/data/all-in-one"
export UI_DIST="$release/ui-dist"
export MIHOMO_REAL_BIN="$release/mihomo"
export MIHOMO_BIN="$SELF"
export TMPDIR="$MODULE/runtime/host/tmp"
export MIHOMO_KERNEL_TMPDIR="$TMPDIR/legacy-kernel"
umask 077
mkdir -p "$MIHOMO_KERNEL_TMPDIR"
export CONTROL_TOKEN="${MIHOMO_CONTROL_TOKEN:?MIHOMO_CONTROL_TOKEN missing}"
export CLASH_SECRET="${MIHOMO_API_SECRET:?MIHOMO_API_SECRET missing}"
export CONTROL_PORT="${MIHOMO_API_PORT:-7012}"
export CLASH_API_PORT="${MIHOMO_CORE_API_PORT:-7013}"
export MIXED_PORT="${MIHOMO_MIXED_PORT:-7011}"
export MIHOMO_PROXY_BIND_IP="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
export MIHOMO_CORE_API_BIND_IP="${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
export MIHOMO_MIXED_PORT="$MIXED_PORT"
export MIHOMO_CORE_API_PORT="$CLASH_API_PORT"
export NITRO_HOST="${MIHOMO_API_BIND_IP:-0.0.0.0}"
export PORT="$CONTROL_PORT"
export TZ="${TZ:-Asia/Shanghai}"
exec "$node" "$release/server/index.mjs"
