#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo "grant.sh 测试需要 root"; exit 1; }
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/deploy/easyhostagent/deploy" "$tmp/deploy/state" "$tmp/stage/etc/easyhostagent" "$tmp/bin"
cp -- "$repo/easyhostagent/deploy/grant.sh" "$tmp/deploy/easyhostagent/deploy/grant.sh"
cat > "$tmp/deploy/.env" <<'EOF'
EASYHOSTAGENT_TRANSPORT=http
EASYHOSTAGENT_APP_GRANTS=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
EOF
cat > "$tmp/stage/etc/easyhostagent/agent.env" <<'EOF'
EASYHOSTAGENT_DATA_DIR=/test/data
EASYHOSTAGENT_APP_GRANTS=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
EOF
cat > "$tmp/bin/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
    restart|is-active) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/systemctl"
chmod 0600 "$tmp/deploy/.env" "$tmp/stage/etc/easyhostagent/agent.env"
export PATH="$tmp/bin:$PATH"
export EASYHOSTAGENT_STAGING_ROOT="$tmp/stage"
export EASYHOSTAGENT_TEST_BINARY=/bin/true

controller=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
source_id=cccccccc-cccc-4ccc-8ccc-cccccccccccc
bash "$tmp/deploy/easyhostagent/deploy/grant.sh" "$controller" "$source_id" sub2api portainer

expected="$controller/$source_id/sub2api,$controller/$source_id/portainer"
for envfile in "$tmp/deploy/.env" "$tmp/stage/etc/easyhostagent/agent.env"; do
    grep -Fq "EASYHOSTAGENT_APP_GRANTS=" "$envfile"
    grep -Fq "$expected" "$envfile"
    grep -Fq "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" "$envfile"
    [[ "$(grep -c '^EASYHOSTAGENT_APP_GRANTS=' "$envfile")" -eq 1 ]]
    [[ "$(stat -c '%a' "$envfile")" == 600 ]]
done
bash "$tmp/deploy/easyhostagent/deploy/grant.sh" "$controller" "$source_id" sub2api portainer
[[ "$(grep -o "$controller/$source_id/sub2api" "$tmp/deploy/.env" | wc -l)" -eq 1 ]]
[[ "$(grep -o "$controller/$source_id/portainer" "$tmp/deploy/.env" | wc -l)" -eq 1 ]]

before="$(sha256sum "$tmp/deploy/.env" | cut -d' ' -f1)"
if bash "$tmp/deploy/easyhostagent/deploy/grant.sh" "$controller" "$source_id" qoder2api-hub >"$tmp/reject.log" 2>&1; then
    echo "禁止对非白名单应用自动授权" >&2
    exit 1
fi
[[ "$before" == "$(sha256sum "$tmp/deploy/.env" | cut -d' ' -f1)" ]]

cat > "$tmp/bin/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
    restart) exit 1 ;;
    is-active) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod 0755 "$tmp/bin/systemctl"
if bash "$tmp/deploy/easyhostagent/deploy/grant.sh" "$controller" "$source_id" sub2api >"$tmp/rollback.log" 2>&1; then
    echo "服务重启失败不能声称已授权" >&2
    exit 1
fi
[[ "$before" == "$(sha256sum "$tmp/deploy/.env" | cut -d' ' -f1)" ]]
echo 'Agent 按应用授权、去重、拒绝越权和配置回滚测试通过'
