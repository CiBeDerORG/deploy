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
# Test the downloaded release in its default direct mode first. A moving
# release tag can still serve an older Agent while the new assets upload.
# Configure the controller URL only after confirming this binary supports
# the new standalone-URL reverse pairing protocol.
# 测试调用端未导出 SOFTWARE_ROOT：安装器应使用显式传入的根目录。
env -u SOFTWARE_ROOT bash macos/agent-install.sh install "$SOFTWARE_ROOT" --no-start
[[ -x "$binary" && -f "$plist" ]]
plutil -lint "$plist"
bash deploy.sh easyhostagent identity >"$RUNNER_TEMP/phase1-identity"
grep -q '^Agent ID: ' "$RUNNER_TEMP/phase1-identity"
# The lifecycle test downloads a pinned release that can predate the new pair CLI.
# Do not misreport this as a new-protocol test; exercise it only for a supporting binary.
if EASYHOSTAGENT_DATA_DIR="$state" "$binary" -pair-status >"$RUNNER_TEMP/phase1-pair-status" 2>&1; then
    # New binary supports Controller URL without the old Discovery Token.
    sed -i '' 's#^EASYHOSTAGENT_CONTROLLER_URL=.*#EASYHOSTAGENT_CONTROLLER_URL=https://127.0.0.1:7017#' "$SOFTWARE_ROOT/deploy/.env"
    grep -q '^EASYHOSTAGENT_CONTROLLER_URL=https://127.0.0.1:7017$' "$SOFTWARE_ROOT/deploy/.env"
    pair_token="$(printf '%064d' 0)"
    printf '%s\n' "$pair_token" | bash deploy.sh easyhostagent pair >"$RUNNER_TEMP/phase1-pairing"
    grep -q '一次性 Token 已安全保存' "$RUNNER_TEMP/phase1-pairing"
    [[ -f "$state/reverse-bootstrap.json" ]]
    [[ "$(stat -f '%Lp' "$state/reverse-bootstrap.json")" == 600 ]]
else
    # Do not mask the legacy binary's install/lifecycle compatibility test by
    # injecting an invalid Controller-only setting. Dedicated Agent CI checks
    # the new -pair protocol; this suite still verifies the old release.
    echo "当前下载的 Release 尚无 -pair-status，跳过新配对验收并继续验证原生安装生命周期"
    ! grep -q '^EASYHOSTAGENT_CONTROLLER_URL=https://127.0.0.1:7017$' "$SOFTWARE_ROOT/deploy/.env"
fi
! grep -q '^EASYHOSTAGENT_DISCOVERY_TOKEN=' "$SOFTWARE_ROOT/deploy/.secrets"
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
    # 第二阶段 Docker API 与持久任务入口必须存在且拒绝未配对控制端。
    inventory_code="$(curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1:7018/v1/docker/inventory)"
    task_code="$(curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1:7018/v1/tasks)"
    market_code="$(curl -ksS -X POST -H 'Content-Type: application/json' -d '{"apps":[]}' -o /dev/null -w '%{http_code}' https://127.0.0.1:7018/v1/apps/status)"
    [[ "$inventory_code" == 401 && "$task_code" == 401 && "$market_code" == 401 ]] || {
        echo "Docker 资源、任务与应用市场接口鉴权验收失败：$inventory_code/$task_code/$market_code" >&2
        exit 1
    }
    bash deploy.sh easyhostagent status >/dev/null
    lifecycle_log="$SOFTWARE_ROOT/deploy/state/easyhostagent-macos-lifecycle.log"
    [[ -f "$lifecycle_log" ]] || { echo "缺少 Agent 生命周期日志" >&2; exit 1; }
    grep -q 'launchctl bootstrap' "$lifecycle_log"
    grep -q '健康检查通过' "$lifecycle_log"

    # 模拟另一个更新进程持有锁，第二个 deploy 入口必须明确拒绝并记录原因。
    lockf -k "$SOFTWARE_ROOT/deploy/state/easyhostagent.macos-update.lock" /bin/sleep 3 &
    lock_pid=$!
    sleep 1
    if bash deploy.sh easyhostagent update >"$RUNNER_TEMP/agent-lock-conflict.out" 2>&1; then
        echo "并发 EasyHostAgent 更新没有被锁阻止" >&2
        kill "$lock_pid" 2>/dev/null || true
        exit 1
    fi
    wait "$lock_pid"
    grep -q '更新锁被占用' "$RUNNER_TEMP/agent-lock-conflict.out"
    grep -q 'stage=获取更新锁' "$lifecycle_log"
else
    echo "Runner 没有 gui/${uid}，跳过 launchctl 实际注册验证"
fi
# 执行完整更新，验证旧服务 bootout、端口释放、重新 bootstrap 和健康检查。
env -u SOFTWARE_ROOT bash macos/agent-install.sh update "$SOFTWARE_ROOT"
bash deploy.sh easyhostagent status >/dev/null
bash deploy.sh easyhostagent identity >"$RUNNER_TEMP/phase1-identity-after"
cmp "$RUNNER_TEMP/phase1-identity" "$RUNNER_TEMP/phase1-identity-after"
grep -q '旧 LaunchAgent 已从' "$lifecycle_log"
grep -q '健康检查通过' "$lifecycle_log"
bash deploy.sh easyhostagent uninstall
[[ ! -e "$binary" && ! -e "$plist" && -f "$state/identity.json" ]]
echo "EasyHostAgent macOS 原生安装与身份保留验证通过"
