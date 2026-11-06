#!/usr/bin/env bash
# macOS Runner：测试实际已发布的 ARM64 二进制、校验和、plist 与配对。
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || exit 1
[[ "$(uname -m)" == arm64 ]] || { echo "该测试要求 Apple Silicon Runner"; exit 0; }
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export SOFTWARE_ROOT="$RUNNER_TEMP/easyhostagent-native-phase1"
mkdir -p "$SOFTWARE_ROOT"
chmod 0700 "$SOFTWARE_ROOT"
label=org.cibeder.easyhostagent
uid="$(id -u)"
plist="$HOME/Library/LaunchAgents/$label.plist"
binary="$SOFTWARE_ROOT/easyhostagent/native/bin/easyhostagent"
state="$HOME/Library/Application Support/EasyHostAgent"
cleanup() {
    if [[ -f "$SOFTWARE_ROOT/easyhostagent/native/.managed-by-macos-deploy" ]]; then
        bash deploy.sh easyhostagent uninstall >/dev/null || true
    fi
}
trap cleanup EXIT
bash deploy.sh env
# 首先在不启动 launchd 的模式下验证真实程序的安装、哈希校验和 plist 生成。
bash macos/agent-install.sh install "$SOFTWARE_ROOT" --no-start
[[ -x "$binary" && -f "$plist" ]]
plutil -lint "$plist"
bash deploy.sh easyhostagent identity >"$RUNNER_TEMP/phase1-identity"
grep -q '^Agent ID: ' "$RUNNER_TEMP/phase1-identity"
bash deploy.sh easyhostagent pairing >"$RUNNER_TEMP/phase1-pairing"
grep -q '^One-time pairing code: ' "$RUNNER_TEMP/phase1-pairing"
[[ -f "$state/identity.json" ]]
[[ "$(stat -f '%Lp' "$state/identity.json")" == 600 ]]
# macOS CI 的 GUI 登录域可用时，再执行真实 launchd bootstrap + HTTPS 健康检查。
if launchctl print "gui/$uid" >/dev/null 2>&1; then
    bash deploy.sh easyhostagent install
    launchctl print "gui/$uid/$label" >/dev/null
    for i in {1..30}; do
        if curl -kfsS --silent https://127.0.0.1:7018/v1/health >"$RUNNER_TEMP/eha-health.json"; then break; fi
        sleep 1
    done
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"]=="ready"' "$RUNNER_TEMP/eha-health.json"
    bash deploy.sh easyhostagent status >/dev/null
else
    echo "Runner 没有 gui/$uid，跳过 launchctl 实际注册验证"
fi
bash macos/agent-install.sh update "$SOFTWARE_ROOT" --no-start
bash deploy.sh easyhostagent identity >"$RUNNER_TEMP/phase1-identity-after"
cmp "$RUNNER_TEMP/phase1-identity" "$RUNNER_TEMP/phase1-identity-after"
bash deploy.sh easyhostagent uninstall
[[ ! -e "$binary" && ! -e "$plist" && -f "$state/identity.json" ]]
echo "EasyHostAgent macOS 原生安装与身份保留验证通过"
