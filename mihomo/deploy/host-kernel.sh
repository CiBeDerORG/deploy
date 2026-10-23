#!/usr/bin/env bash
# Derive a native-only runtime copy using the upstream locked YAML dependency.
set -Eeuo pipefail
HERE="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
: "${MIHOMO_REAL_BIN:?Missing native mihomo executable}"
[ -x "$MIHOMO_REAL_BIN" ] || { echo "Native Mihomo binary missing" >&2; exit 1; }
args=("$@")
config_index=-1
for ((i=0; i < ${#args[@]}; i++)); do
    if [ "${args[i]}" = -f ] || [ "${args[i]}" = --config ]; then
        (( i + 1 < ${#args[@]} )) || { echo "Missing config path" >&2; exit 2; }
        (( config_index < 0 )) || { echo "Repeated config argument" >&2; exit 2; }
        config_index=$((i + 1))
        ((i+=1))
    fi
done
if (( config_index < 0 )); then exec "$MIHOMO_REAL_BIN" "$@"; fi
node="${MIHOMO_NODE_BIN:-$HERE/../node/bin/node}"
[ -x "$node" ] || { echo "Release Node runtime missing" >&2; exit 1; }
: "${MIHOMO_KERNEL_TMPDIR:?Missing module-local kernel temporary directory}"
umask 077
mkdir -p "$MIHOMO_KERNEL_TMPDIR"
tmp="$(mktemp "$MIHOMO_KERNEL_TMPDIR/active.XXXXXXXX.yaml")"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT
"$node" "$HERE/host-config.mjs" "${args[config_index]}" "$tmp"
# Preserve the PID tracked by the official supervisor, which can SIGKILL this
# process on ready/stop timeout. A background child would survive that signal.
# Linux keeps this read-only descriptor open through exec; unlink the pathname
# now so credentials leave no temporary files, including on forced termination.
exec {config_fd}<"$tmp"
rm -f -- "$tmp"
trap - EXIT
args[config_index]="/proc/self/fd/$config_fd"
exec "$MIHOMO_REAL_BIN" "${args[@]}"
