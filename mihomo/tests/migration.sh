#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../deploy/common.sh
source "$HERE/../deploy/common.sh"
# shellcheck source=../deploy/migrate.sh
source "$HERE/../deploy/migrate.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
SECRETS_FILE="$work/.secrets"
: > "$SECRETS_FILE"
MIHOMO_PROXY_USER=deploy
MIHOMO_PROXY_PASSWORD=
mkdir -p "$work/legacy"
cat > "$work/legacy/config.yaml" <<'EOF_CONFIG'
mixed-port: 7890
external-controller: 0.0.0.0:9090
external-ui: /root/.config/mihomo/ui
external-ui-url: https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip
authentication:
  - 'deploy: preserved: # "quoted" 中文'
rules:
  - MATCH,DIRECT
EOF_CONFIG
old="$(cat "$work/legacy/config.yaml")"
initialize_aio "$work/legacy" "$HERE/../deploy/default-profile.yaml" 7012
d="$work/legacy/all-in-one"
[[ "$(cat "$work/legacy/config.yaml")" == "$old" ]]
cmp "$work/legacy/config.yaml" "$work/legacy/backup/pre-all-in-one/config.yaml"
! grep -q '^external-ui-url:' "$d/profiles/deploy-initial.yaml"
grep -F "'deploy: preserved: # \"quoted\" 中文'" "$d/profiles/deploy-proxy-auth.yaml" >/dev/null
grep -F "'http://127.0.0.1:7012'" "$d/profiles/deploy-web-cors.yaml" >/dev/null
grep -F "'deploy: preserved: # \"quoted\" 中文'" "$d/active.yaml" >/dev/null
python3 - "$d" <<'PY'
import json
import pathlib
import sys
data = pathlib.Path(sys.argv[1]) / "profiles"
items = json.loads((data / "index.json").read_text())
assert [p["id"] for p in items] == ["deploy-initial", "deploy-web-cors", "deploy-proxy-auth"]
assert json.loads((data / "state.json").read_text()) == {"activeId": "deploy-initial"}
PY
old_index="$(cat "$d/profiles/index.json")"
initialize_aio "$work/legacy" "$HERE/../deploy/default-profile.yaml" 7012
[[ "$(cat "$d/profiles/index.json")" == "$old_index" ]]

# Blank-only generation on a genuinely fresh install.
mkdir -p "$work/new"
printf 'MIHOMO_PROXY_PASSWORD=\n' > "$SECRETS_FILE"
MIHOMO_PROXY_PASSWORD=
initialize_aio "$work/new" "$HERE/../deploy/default-profile.yaml" 7012
[[ "$MIHOMO_PROXY_PASSWORD" =~ ^[a-f0-9]{64}$ ]]
grep -Fx "MIHOMO_PROXY_PASSWORD=$MIHOMO_PROXY_PASSWORD" "$SECRETS_FILE" >/dev/null
grep -F "deploy:$MIHOMO_PROXY_PASSWORD" "$work/new/all-in-one/profiles/deploy-proxy-auth.yaml" >/dev/null

# Existing but incomplete data must fail rather than be silently overwritten.
mkdir -p "$work/partial/all-in-one"
echo marker > "$work/partial/all-in-one/user-owned"
if (initialize_aio "$work/partial" "$HERE/../deploy/default-profile.yaml" 7012) >/dev/null 2>&1; then
    echo 'Incomplete data overwritten' >&2; exit 1
fi
test -f "$work/partial/all-in-one/user-owned"
echo 'Fresh migration / persistence regression passed'
