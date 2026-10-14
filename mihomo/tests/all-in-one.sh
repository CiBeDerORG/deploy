#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../deploy/lib.sh
source "$SCRIPT_DIR/../deploy/lib.sh"

# Exact origin CORS, no permissive wildcard.
cors="$(write_web_cors 7012 "http://10.10.10.2:7012")"
grep -F "external-controller-cors:" <<< "$cors" >/dev/null
grep -F "allow-private-network: true" <<< "$cors" >/dev/null
grep -F "'http://10.10.10.2:7012'" <<< "$cors" >/dev/null
if grep -F "'*'" <<< "$cors"; then
    echo 'CORS wildcard is not permitted by deploy defaults' >&2
    exit 1
fi
if (write_web_cors 7012 "https://bad.invalid/extra") >/dev/null 2>&1; then
    echo 'Non-origin URL unexpectedly accepted' >&2
    exit 1
fi

# The new module is official AIO, not static UI downloading.
grep -F 'ghcr.io/metacubex/metacubexd-server:latest' "$SCRIPT_DIR/../deploy/docker-compose.yaml" >/dev/null
! grep -F 'external-ui-url:' "$SCRIPT_DIR/../deploy/profile.example.yaml"
grep -F 'MIHOMO_CONTROL_TOKEN' "$SCRIPT_DIR/../deploy/install.sh" >/dev/null
grep -F 'data/all-in-one' "$SCRIPT_DIR/../deploy/install.sh" >/dev/null

# Legacy profile copying must not touch the source file or its auth credentials.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/legacy.yaml" <<'EOF'
mixed-port: 7890
external-controller: 0.0.0.0:9090
external-ui: /root/.config/mihomo/ui
external-ui-url: https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip
authentication:
  - 'deploy:With : # quotes and 中文'
rules:
  - MATCH,DIRECT
EOF
original="$(cat "$tmp/legacy.yaml")"
sed '/^external-ui:/d; /^external-ui-url:/d' "$tmp/legacy.yaml" > "$tmp/profile.yaml"
[[ "$(cat "$tmp/legacy.yaml")" == "$original" ]]
grep -F "deploy:With : # quotes and 中文" "$tmp/profile.yaml" >/dev/null
! grep -q '^external-ui-url:' "$tmp/profile.yaml"
extract_legacy_authentication "$tmp/profile.yaml" > "$tmp/auth.yaml"
grep -F "deploy:With : # quotes and 中文" "$tmp/auth.yaml" >/dev/null
! grep -q '^rules:' "$tmp/auth.yaml"
echo 'MetaCubeXD All-in-One default and legacy migration checks passed.'
