#!/usr/bin/env bash
# Native listener policy regression. No root, systemd, Docker or network needed.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cat > "$work/mihomo" <<'EOF_CORE'
#!/usr/bin/env bash
set -Eeuo pipefail
while [ "$#" -gt 0 ]; do
    if [ "$1" = -f ] || [ "$1" = --config ]; then
        cat "$2"
        exit 0
    fi
    shift
done
exit 2
EOF_CORE
chmod +x "$work/mihomo"
cat > "$work/active.yaml" <<'EOF_CONFIG'
external-controller: 0.0.0.0:9090
mixed-port: 7890
allow-lan: true
bind-address: "*"
authentication:
  - 'deploy:keep-secret'
external-controller-cors:
  allow-origins:
    - 'http://127.0.0.1:7012'
rules:
  - MATCH,DIRECT
EOF_CONFIG
cp "$work/active.yaml" "$work/original.yaml"
export MIHOMO_REAL_BIN="$work/mihomo"
export MIHOMO_KERNEL_TMPDIR="$work/tmp"
export MIHOMO_PROXY_BIND_IP=127.0.0.1
export MIHOMO_CORE_API_BIND_IP=0.0.0.0
export MIHOMO_MIXED_PORT=7011
export MIHOMO_CORE_API_PORT=7013
output="$(bash "$HERE/../deploy/host-kernel.sh" -t -d "$work" -f "$work/active.yaml")"
grep -Fx 'external-controller: "0.0.0.0:7013"' <<< "$output"
grep -Fx 'mixed-port: 7011' <<< "$output"
grep -Fx 'bind-address: "127.0.0.1"' <<< "$output"
grep -Fx "  - 'deploy:keep-secret'" <<< "$output"
grep -Fx "    - 'http://127.0.0.1:7012'" <<< "$output"
[ "$(grep -c '^mixed-port:' <<< "$output")" -eq 1 ]
[ "$(grep -c '^external-controller:' <<< "$output")" -eq 1 ]
cmp -s "$work/active.yaml" "$work/original.yaml"

# The wildcard proxy bind must be Mihomo's documented "*" value.
export MIHOMO_PROXY_BIND_IP=0.0.0.0
export MIHOMO_CORE_API_BIND_IP=127.0.0.1
output="$(bash "$HERE/../deploy/host-kernel.sh" -t -f "$work/active.yaml")"
grep -Fx 'bind-address: "*"' <<< "$output"
grep -Fx 'external-controller: "127.0.0.1:7013"' <<< "$output"
cmp -s "$work/active.yaml" "$work/original.yaml"
[ "$(find "$work/tmp" -name 'active.*.yaml' -type f | wc -l)" -eq 2 ]
echo "Native Mihomo config isolation and listener regression passed"
