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
    -pair-status) echo "${EASYHOSTAGENT_TEST_PAIR_STATUS:-paired=false}"; exit 0 ;;
    -pair)
        token="$(cat)"
        [ "${#token}" -eq 64 ] || exit 1
        printf 'pair request accepted\nPAIRING_DATA_DIR=%s\nPAIR_TOKEN_LENGTH=%s\nPAIR_REPLACED=%s\n' "${EASYHOSTAGENT_DATA_DIR:-}" "${#token}" "${2:-none}"
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

# pair 只读取本机原生配置并接收一次性 Token，不安装、不更新，也不将 Token 写入配置。
sed -i 's#^EASYHOSTAGENT_CONTROLLER_URL=.*#EASYHOSTAGENT_CONTROLLER_URL=https://control.example.com#' "$file"
bash deploy.sh easyhostagent update > "$tmp/pair-config.log" 2>&1 || { cat "$tmp/pair-config.log"; exit 1; }
cp -- "$native" "$tmp/native.env.backup"
sed -i 's#^EASYHOSTAGENT_DATA_DIR=.*#EASYHOSTAGENT_DATA_DIR=/test-only/agent/data#' "$native"
pair_token="$(printf '%064d' 0)"
pairing_output="$(printf '%s\n' "$pair_token" | bash deploy.sh easyhostagent pair)" || { echo "pair 命令执行失败" >&2; exit 1; }
grep -Fq 'pair request accepted' <<< "$pairing_output"
grep -Fq 'PAIRING_DATA_DIR=/test-only/agent/data' <<< "$pairing_output"
grep -Fq 'PAIR_TOKEN_LENGTH=64' <<< "$pairing_output"
grep -Fq 'PAIR_REPLACED=none' <<< "$pairing_output"
# Exercise explicit confirmation and cancellation without ever printing the Token.
repaired_output="$(printf 'y\n%s\n' "$pair_token" | EASYHOSTAGENT_TEST_PAIR_STATUS=paired=true bash deploy.sh easyhostagent pair)" || {
    echo "重新配对确认场景执行失败" >&2; exit 1
}
grep -Fq 'PAIR_REPLACED=-pair-replace' <<< "$repaired_output"
cancelled_output="$(printf 'n\n' | EASYHOSTAGENT_TEST_PAIR_STATUS=paired=true bash deploy.sh easyhostagent pair 2>&1)" || {
    echo "取消重新配对场景不应失败" >&2; exit 1
}
grep -Fq '已取消；原配对信息保持不变' <<< "$cancelled_output"
! grep -Fq "$pair_token" <<< "$repaired_output"
! grep -Fq "$pair_token" <<< "$pairing_output"
cp -- "$tmp/native.env.backup" "$native"
if printf '%s\n' "$pair_token" | bash deploy.sh easynettopo pair > "$tmp/wrong-task.log" 2>&1; then
    echo "配对操作不应允许其他业务" >&2; exit 1
fi
grep -Fq 'pair 仅支持 easyhostagent' "$tmp/wrong-task.log"

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

# 反向接入只保留控制端地址；旧版 Bootstrap Token 从 .env/.secrets/Agent 配置中清除。
bootstrap_token="$(printf '%064d' 0)"
secret_file="$SOFTWARE_ROOT/deploy/.secrets"
printf 'EASYHOSTAGENT_DISCOVERY_TOKEN=%s\n' "$bootstrap_token" >> "$secret_file"
printf 'EASYHOSTAGENT_DISCOVERY_TOKEN=%s\n' "$bootstrap_token" >> "$native"
chmod 0600 "$secret_file"
sed -i 's#^EASYHOSTAGENT_CONTROLLER_URL=.*#EASYHOSTAGENT_CONTROLLER_URL=http://192.168.10.2:7017#' "$file"
bash deploy.sh easyhostagent update > "$tmp/http-controller.log" 2>&1 || { cat "$tmp/http-controller.log"; exit 1; }
grep -qx 'EASYHOSTAGENT_CONTROLLER_URL=http://192.168.10.2:7017' "$native"
! grep -q '^EASYHOSTAGENT_DISCOVERY_TOKEN=' "$native"
! grep -q '^EASYHOSTAGENT_DISCOVERY_TOKEN=' "$secret_file"
! grep -q '^EASYHOSTAGENT_DISCOVERY_TOKEN=' "$file"
grep -Fq '反向接入正在使用 HTTP 明文传输' "$tmp/http-controller.log"

sed -i 's#^EASYHOSTAGENT_CONTROLLER_URL=.*#EASYHOSTAGENT_CONTROLLER_URL=ftp://192.168.10.2:7017#' "$file"
if bash deploy.sh easyhostagent update > "$tmp/bad-controller.log" 2>&1; then
    echo "Agent 接受了非法反向控制端协议" >&2; exit 1
fi
grep -Fq '必须是 HTTP 或 HTTPS 地址' "$tmp/bad-controller.log"
grep -qx 'EASYHOSTAGENT_CONTROLLER_URL=http://192.168.10.2:7017' "$native"
sed -i 's#^EASYHOSTAGENT_CONTROLLER_URL=.*#EASYHOSTAGENT_CONTROLLER_URL=https://control.example.com#' "$file"
bash deploy.sh easyhostagent update > "$tmp/https-controller.log" 2>&1 || { cat "$tmp/https-controller.log"; exit 1; }
grep -qx 'EASYHOSTAGENT_CONTROLLER_URL=https://control.example.com' "$native"

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
