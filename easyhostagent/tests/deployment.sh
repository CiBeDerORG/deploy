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
case "${1:-}" in
    -version) echo "test-agent"; exit 0 ;;
    -pairing-code)
        printf 'Agent ID: test-agent-uuid\nTLS SPKI SHA-256: test-fingerprint\nOne-time pairing code: test-single-use-code\nExpires (UTC): 2030-01-01T00:00:00Z\n'
        printf 'PAIRING_DATA_DIR=%s\n' "${EASYHOSTAGENT_DATA_DIR:-}"
        exit 0 ;;
    *) exit 1 ;;
esac
BIN
chmod 0755 "$EASYHOSTAGENT_TEST_BINARY"
cd "$repo"
bash deploy.sh list | grep -Fx easyhostagent >/dev/null || bash deploy.sh list | grep -F easyhostagent >/dev/null
bash deploy.sh env >/dev/null
file="$SOFTWARE_ROOT/deploy/.env"
test -f "$file"
grep -qx "GITHUB_RELEASE_SOURCE=mirror" "$file"
grep -qx "GITHUB_RELEASE_MIRRORS=ghproxy,ghfast,ghproxy-net" "$file"
! grep -q '^EASYHOSTAGENT_RELEASE=' "$file"
grep -qx 'EASYHOSTAGENT_RELEASE=v0.1.0-deploy-manifest-lifecycle.dev' "$SOFTWARE_ROOT/deploy/lib/versions.env"
grep -qx 'EASYHOSTAGENT_TRANSPORT=https' "$file"
grep -qx 'EASYHOSTAGENT_LOCAL_BINARY=' "$file"
grep -qx 'EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018' "$file"
grep -qx 'EASYHOSTAGENT_PLATFORM=' "$file"
bash deploy.sh easyhostagent install > "$tmp/install.log" 2>&1 || { cat "$tmp/install.log"; exit 1; }
test -f "$SOFTWARE_ROOT/deploy/lib/release-sources.sh"
native="$EASYHOSTAGENT_STAGING_ROOT/etc/easyhostagent/agent.env"
test -f "$native"
test -f "$EASYHOSTAGENT_STAGING_ROOT/etc/easyhostagent/managed-by-installer"
test -x "$EASYHOSTAGENT_STAGING_ROOT/usr/local/bin/easyhostagent"
grep -qx 'EASYHOSTAGENT_TRANSPORT=https' "$native"
grep -qx "EASYHOSTAGENT_SOFTWARE_ROOT=$SOFTWARE_ROOT" "$native"
! grep -q '^EASYHOSTAGENT_PLATFORM=' "$native"
test "$(stat -c '%a' "$native")" = 600

# pairing 只调用原生 Agent，在没有安装/同步操作时读取原生 EnvironmentFile。
# 临时覆盖测试环境内的原生数据目录，确认不会错误生成默认目录下的另一份身份。
cp -- "$native" "$tmp/native.env.backup"
sed -i 's#^EASYHOSTAGENT_DATA_DIR=.*#EASYHOSTAGENT_DATA_DIR=/test-only/agent/data#' "$native"
pairing_output="$(bash deploy.sh easyhostagent pairing)" || { echo "pairing 命令执行失败" >&2; exit 1; }
grep -Fq 'Agent ID: test-agent-uuid' <<< "$pairing_output"
grep -Fq 'TLS SPKI SHA-256: test-fingerprint' <<< "$pairing_output"
grep -Fq 'One-time pairing code: test-single-use-code' <<< "$pairing_output"
grep -Fq 'Expires (UTC): 2030-01-01T00:00:00Z' <<< "$pairing_output"
grep -Fq 'PAIRING_DATA_DIR=/test-only/agent/data' <<< "$pairing_output"
cp -- "$tmp/native.env.backup" "$native"
if bash deploy.sh easynettopo pairing > "$tmp/wrong-task.log" 2>&1; then
    echo "配对操作不应允许其他业务" >&2; exit 1
fi
grep -Fq 'pairing 仅支持 easyhostagent' "$tmp/wrong-task.log"

# 持久化身份、未知本地配置在更新时必须保留。
# 模拟旧 .env 残留自定义 Release，后续更新必须忽略并清理它。
printf 'EASYHOSTAGENT_RELEASE=v0.1.0-appstore.dev\n' >> "$file"
persisted="$EASYHOSTAGENT_STAGING_ROOT/var/lib/easyhostagent/identity.json"
printf 'persisted-identity' > "$persisted"
printf 'CUSTOM_AGENT_SETTING=keep\n' >> "$native"
# 显式 fnOS 配置必须传递给原生 Agent，而不是被安装脚本忽略。
sed -i 's/^EASYHOSTAGENT_PLATFORM=.*/EASYHOSTAGENT_PLATFORM=fnos/' "$file"
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http/' "$file"
sed -i 's/^EASYHOSTAGENT_LISTEN_ADDRESS=.*/EASYHOSTAGENT_LISTEN_ADDRESS=127.0.0.1:7018/' "$file"
# 历史用户的授权配置即使存在也仅作兼容保留；新安装不再创建该键。
legacy_grant='11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222'
printf 'EASYHOSTAGENT_APP_GRANTS=%s\n' "$legacy_grant" >> "$file"
printf 'EASYHOSTAGENT_APP_GRANTS=%s\n' "$legacy_grant" >> "$native"
# 离线模式使用上传的程序和同名 SHA-256，模拟真实用户切换安装来源。
uploaded="$tmp/easyhostagent-linux-amd64"
cp "$EASYHOSTAGENT_TEST_BINARY" "$uploaded"
(cd "$tmp" && sha256sum easyhostagent-linux-amd64 > easyhostagent-linux-amd64.sha256)
sed -i "s#^EASYHOSTAGENT_LOCAL_BINARY=.*#EASYHOSTAGENT_LOCAL_BINARY=$uploaded#" "$file"
# SHA 校验失败时，现有安装和身份状态不应受到影响。
printf 'tampered' >> "$uploaded"
if bash deploy.sh easyhostagent update > "$tmp/bad-checksum.log" 2>&1; then
    echo "未拒绝篡改的 Agent 本地二进制" >&2; exit 1
fi
grep -F 'SHA-256 校验失败' "$tmp/bad-checksum.log" >/dev/null
! grep -q '^EASYHOSTAGENT_RELEASE=' "$file"
grep -Fxq 'EASYHOSTAGENT_RELEASE=v0.1.0-deploy-manifest-lifecycle.dev' "$SOFTWARE_ROOT/deploy/lib/versions.env"
test "$(cat "$persisted")" = persisted-identity
cp "$EASYHOSTAGENT_TEST_BINARY" "$uploaded"
bash deploy.sh easyhostagent update > "$tmp/update.log" 2>&1 || { cat "$tmp/update.log"; exit 1; }
grep -qx 'EASYHOSTAGENT_TRANSPORT=http' "$native"
! grep -q '^EASYHOSTAGENT_RELEASE=' "$file"
grep -Fxq 'EASYHOSTAGENT_RELEASE=v0.1.0-deploy-manifest-lifecycle.dev' "$SOFTWARE_ROOT/deploy/lib/versions.env"
grep -qx 'EASYHOSTAGENT_LISTEN_ADDRESS=127.0.0.1:7018' "$native"
grep -qx 'CUSTOM_AGENT_SETTING=keep' "$native"
grep -qx 'EASYHOSTAGENT_PLATFORM=fnos' "$native"
grep -Fxq "EASYHOSTAGENT_APP_GRANTS=$legacy_grant" "$native"
# 老配置值只保留，不应重复写入或自动扩大授权范围。
test "$(grep -c '^EASYHOSTAGENT_APP_GRANTS=' "$native")" -eq 1
test "$(cat "$persisted")" = persisted-identity

# 不接受无效平台，已有原生平台与配对数据不得修改。
sed -i 's/^EASYHOSTAGENT_PLATFORM=.*/EASYHOSTAGENT_PLATFORM=unknown/' "$file"
if bash deploy.sh easyhostagent update > "$tmp/invalid-platform.log" 2>&1; then
    echo "Agent 接受了非法平台" >&2; exit 1
fi
grep -Fq 'Agent 平台只能为' "$tmp/invalid-platform.log"
grep -qx 'EASYHOSTAGENT_PLATFORM=fnos' "$native"
sed -i 's/^EASYHOSTAGENT_PLATFORM=.*/EASYHOSTAGENT_PLATFORM=/' "$file"
# 留空平台时，原生配置已有的显式平台值仍需保留。
bash deploy.sh easyhostagent update > "$tmp/empty-platform.log" 2>&1 || { cat "$tmp/empty-platform.log"; exit 1; }
grep -qx 'EASYHOSTAGENT_PLATFORM=fnos' "$native"

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

# 已安装后的统一配置不能无意间迁移 Agent 身份状态目录。
sed -i 's#^EASYHOSTAGENT_DATA_DIR=.*#EASYHOSTAGENT_DATA_DIR=/tmp/another-agent-data#' "$file"
if bash deploy.sh easyhostagent update > "$tmp/migration.log" 2>&1; then
    echo "未阻止 Agent 原数据目录意外迁移" >&2; exit 1
fi
grep -F '与统一 .env 不一致' "$tmp/migration.log" >/dev/null
sed -i 's#^EASYHOSTAGENT_DATA_DIR=.*#EASYHOSTAGENT_DATA_DIR=/var/lib/easyhostagent#' "$file"

# 旧版自定义 Release 即使存在，也不能覆盖仓库的受控版本。
printf 'EASYHOSTAGENT_RELEASE=v2.3.4-custom\n' >> "$file"
bash deploy.sh env >/dev/null
! grep -q '^EASYHOSTAGENT_RELEASE=' "$file"
grep -Fxq 'EASYHOSTAGENT_RELEASE=v0.1.0-deploy-manifest-lifecycle.dev' "$SOFTWARE_ROOT/deploy/lib/versions.env"

bash deploy.sh easyhostagent uninstall > "$tmp/uninstall.log" 2>&1 || { cat "$tmp/uninstall.log"; exit 1; }
test ! -e "$EASYHOSTAGENT_STAGING_ROOT/usr/local/bin/easyhostagent"
test ! -e "$EASYHOSTAGENT_STAGING_ROOT/etc/systemd/system/easyhostagent.service"
test -f "$native"
test "$(cat "$persisted")" = persisted-identity
echo "EasyHostAgent 原生安装、HTTP 配置、更新、数据保留与卸载隔离测试通过"
