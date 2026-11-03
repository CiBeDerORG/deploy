#!/usr/bin/env bash
# 隔离目录测试真实 deploy 入口，不下载文件、不启动主机 systemd、不接触真实 Docker。
set -Eeuo pipefail
(( EUID == 0 )) || { echo "请以 root 运行 EasyHostAgent 隔离测试" >&2; exit 1; }
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export SOFTWARE_ROOT="$tmp/software"
export EASYHOSTAGENT_STAGING_ROOT="$tmp/staging"
export EASYHOSTAGENT_TEST_BINARY="$tmp/easyhostagent-fake"
mkdir -p "$EASYHOSTAGENT_STAGING_ROOT"
cat > "$EASYHOSTAGENT_TEST_BINARY" <<'BIN'
#!/bin/sh
if [ "${1:-}" = "-version" ]; then echo "test-agent"; exit 0; fi
exit 1
BIN
chmod 0755 "$EASYHOSTAGENT_TEST_BINARY"
cd "$repo"
bash deploy.sh list | grep -Fx easyhostagent >/dev/null || bash deploy.sh list | grep -F easyhostagent >/dev/null
bash deploy.sh env >/dev/null
file="$SOFTWARE_ROOT/deploy/.env"
test -f "$file"
grep -qx 'EASYHOSTAGENT_TRANSPORT=https' "$file"
grep -qx 'EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018' "$file"
bash deploy.sh easyhostagent install > "$tmp/install.log" 2>&1 || { cat "$tmp/install.log"; exit 1; }
native="$EASYHOSTAGENT_STAGING_ROOT/etc/easyhostagent/agent.env"
test -f "$native"
test -f "$EASYHOSTAGENT_STAGING_ROOT/etc/easyhostagent/managed-by-installer"
test -x "$EASYHOSTAGENT_STAGING_ROOT/usr/local/bin/easyhostagent"
grep -qx 'EASYHOSTAGENT_TRANSPORT=https' "$native"
grep -qx "EASYHOSTAGENT_SOFTWARE_ROOT=$SOFTWARE_ROOT" "$native"
test "$(stat -c '%a' "$native")" = 600

# 持久化身份、未知本地配置在更新时必须保留。
persisted="$EASYHOSTAGENT_STAGING_ROOT/var/lib/easyhostagent/identity.json"
printf 'persisted-identity' > "$persisted"
printf 'CUSTOM_AGENT_SETTING=keep\n' >> "$native"
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http/' "$file"
sed -i 's/^EASYHOSTAGENT_LISTEN_ADDRESS=.*/EASYHOSTAGENT_LISTEN_ADDRESS=127.0.0.1:7018/' "$file"
sed -i 's#^EASYHOSTAGENT_APP_GRANTS=.*#EASYHOSTAGENT_APP_GRANTS=11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222#' "$file"
bash deploy.sh easyhostagent update > "$tmp/update.log" 2>&1 || { cat "$tmp/update.log"; exit 1; }
grep -qx 'EASYHOSTAGENT_TRANSPORT=http' "$native"
grep -qx 'EASYHOSTAGENT_LISTEN_ADDRESS=127.0.0.1:7018' "$native"
grep -qx 'CUSTOM_AGENT_SETTING=keep' "$native"
grep -Fq '11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222' "$native"
test "$(cat "$persisted")" = persisted-identity

# 不接受注入、无效端口或重复配置；失败不得破坏已生效的 Agent 配置。
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http;false/' "$file"
if bash deploy.sh easyhostagent update > "$tmp/invalid.log" 2>&1; then
    echo "Agent 接受了无效的传输配置" >&2; exit 1
fi
grep -qx 'EASYHOSTAGENT_TRANSPORT=http' "$native"
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http/' "$file"
printf 'EASYHOSTAGENT_TRANSPORT=https\n' >> "$file"
if bash deploy.sh easyhostagent update > "$tmp/duplicate.log" 2>&1; then
    echo "Agent 接受了重复配置" >&2; exit 1
fi
sed -i '$d' "$file"

bash deploy.sh easyhostagent uninstall > "$tmp/uninstall.log" 2>&1 || { cat "$tmp/uninstall.log"; exit 1; }
test ! -e "$EASYHOSTAGENT_STAGING_ROOT/usr/local/bin/easyhostagent"
test ! -e "$EASYHOSTAGENT_STAGING_ROOT/etc/systemd/system/easyhostagent.service"
test -f "$native"
test "$(cat "$persisted")" = persisted-identity
echo "EasyHostAgent 原生安装、HTTP 配置、更新、数据保留与卸载隔离测试通过"
