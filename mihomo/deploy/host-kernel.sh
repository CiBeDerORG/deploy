#!/usr/bin/env bash
# Native-only wrapper. Never edit the shared Agent Profile/active.yaml.
# The official supervisor owns its YAML; give the real core a temporary copy
# with host listen addresses. Docker always continues to use the original.
set -Eeuo pipefail
: "\${MIHOMO_REAL_BIN:?Missing native mihomo executable}"
[ -x "$MIHOMO_REAL_BIN" ] || { echo "Native Mihomo binary missing" >&2; exit 1; }

args=("$@")
config_index=-1
for ((i=0; i < \${#args[@]}; i++)); do
    if [ "\${args[i]}" = -f ] || [ "\${args[i]}" = --config ]; then
        (( i + 1 < \${#args[@]} )) || { echo "Missing config path" >&2; exit 2; }
        config_index=$((i + 1))
        break
    fi
done
if (( config_index < 0 )); then
    exec "$MIHOMO_REAL_BIN" "$@"
fi

config="\${args[config_index]}"
[ -f "$config" ] || { echo "Missing Mihomo profile: $config" >&2; exit 1; }
proxy_ip="\${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
core_ip="\${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
proxy_port="\${MIHOMO_MIXED_PORT:-7011}"
core_port="\${MIHOMO_CORE_API_PORT:-7013}"
[ "$proxy_ip" != 0.0.0.0 ] || proxy_ip='*'
tmpdir="\${MIHOMO_KERNEL_TMPDIR:-/run/deploy-mihomo}"
umask 077
mkdir -p "$tmpdir"
# systemd's RuntimeDirectory removes temporary copies when the service stops.
# Keep the temp file during kernel lifetime; 'exec' preserves SIGTERM handling.
tmp="$(mktemp "$tmpdir/active.XXXXXXXX.yaml")"
if ! awk -v p="$proxy_port" -v a="$proxy_ip" -v c="$core_ip:$core_port" '
    BEGIN {
        print "external-controller: \"" c "\""
        print "mixed-port: " p
        print "allow-lan: true"
        print "bind-address: \"" a "\""
    }
    !/^(external-controller|mixed-port|allow-lan|bind-address):[[:space:]]*/ {print}
' "$config" > "$tmp"; then
    rm -f -- "$tmp"
    exit 1
fi
args[config_index]="$tmp"
exec "$MIHOMO_REAL_BIN" "\${args[@]}"
