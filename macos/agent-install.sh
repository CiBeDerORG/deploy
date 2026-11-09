#!/usr/bin/env bash
# macOS 原生 Agent：普通登录用户安装 launchd LaunchAgent。
set -euo pipefail
umask 077

stage="初始化"
log_file=""
tmp=""
uid=""
launch_label=""
plist=""
binary=""
data_dir=""
port=""
health_url=""

log() {
    local line
    line="[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] [pid=$$] [stage=$stage] $*"
    if [[ -n "$log_file" ]]; then
        printf '%s\n' "$line" | tee -a "$log_file" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

fail() {
    log "ERROR：$*"
    exit 1
}

run_logged() {
    local step_name output rc
    step_name="$1"
    output=""
    rc=0
    shift
    log "命令开始：$step_name"
    if output="$("$@" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [[ -n "$output" ]]; then
        log "命令输出（${step_name}）：$output"
    fi
    log "命令结束：${step_name}，exit=${rc}"
    return "$rc"
}

service_loaded() {
    launchctl print "$launch_label" >/dev/null 2>&1
}

collect_diagnostics() {
    log "========== EasyHostAgent macOS 启动诊断开始 =========="
    if [[ -n "$plist" && -f "$plist" ]]; then
        run_logged "LaunchAgent plist 语法" plutil -lint "$plist" || true
        run_logged "LaunchAgent plist 文件信息" stat -f 'owner=%u mode=%Lp size=%z path=%N' "$plist" || true
    else
        log "LaunchAgent plist 不存在：$plist"
    fi
    if [[ -n "$binary" && -f "$binary" ]]; then
        run_logged "Agent 二进制文件类型" file "$binary" || true
        run_logged "Agent 二进制版本" "$binary" -version || true
        run_logged "Agent 二进制权限" stat -f 'owner=%u mode=%Lp size=%z path=%N' "$binary" || true
    else
        log "Agent 二进制不存在：$binary"
    fi
    if [[ -n "$launch_label" ]]; then
        run_logged "launchctl 服务状态" launchctl print "$launch_label" || true
        run_logged "launchctl 用户 GUI 域" launchctl print "gui/$uid" || true
    fi
    if [[ -n "$port" ]] && command -v lsof >/dev/null 2>&1; then
        run_logged "监听端口 $port" lsof -nP -iTCP:"$port" -sTCP:LISTEN || true
    fi
    if [[ -f "$data_dir/agent.stderr.log" ]]; then
        log "最近 80 行 Agent stderr：$(tail -n 80 "$data_dir/agent.stderr.log" 2>&1)"
    fi
    if [[ -f "$data_dir/agent.stdout.log" ]]; then
        log "最近 40 行 Agent stdout：$(tail -n 40 "$data_dir/agent.stdout.log" 2>&1)"
    fi
    log "详细生命周期日志：$log_file"
    log "========== EasyHostAgent macOS 启动诊断结束 =========="
}

on_exit() {
    local rc=$?
    if [[ -n "$tmp" && -d "$tmp" ]]; then
        rm -rf "$tmp"
    fi
    if [[ -n "$log_file" ]]; then
        if [[ "$rc" -eq 0 ]]; then
            log "脚本结束：成功"
        else
            log "脚本结束：失败，exit=${rc}，stage=${stage}"
            collect_diagnostics || true
        fi
    fi
}
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "目前只支持 macOS Apple Silicon (arm64)"
[[ "$(id -u)" -ne 0 ]] || fail "请用 Mac 当前登录用户执行，不要 sudo"
mode="${1:-install}"
root="${2:-/opt/software}"
no_start="${3:-}"
case "$mode" in install|update|force-update|uninstall|status|pairing|identity) ;; *) fail "命令只支持 install/update/force-update/uninstall/status/pairing/identity" ;; esac
[[ "$root" == /* && -d "$root" && ! -L "$root" ]] || fail "SOFTWARE_ROOT 必须为真实绝对目录"
[[ "$no_start" == "" || "$no_start" == --no-start ]] || fail "只允许 --no-start"

uid="$(id -u)"
label="org.cibeder.easyhostagent"
launch_label="gui/$uid/$label"
home="$(dscl . -read /Users/"$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
[[ -n "$home" && -d "$home" ]] || fail "无法定位 Mac 当前用户目录"
data_dir="$home/Library/Application Support/EasyHostAgent"
app_dir="$root/easyhostagent/native"
binary="$app_dir/bin/easyhostagent"
marker="$app_dir/.managed-by-macos-deploy"
plist_dir="$home/Library/LaunchAgents"
plist="$plist_dir/$label.plist"
env_file="$root/deploy/.env"
state_dir="$root/deploy/state"
[[ ! -L "$root/deploy" && ! -L "$state_dir" ]] || fail "deploy/state 目录不能是符号链接"
mkdir -p "$state_dir" || fail "无法创建更新状态目录：$state_dir"
chmod 0700 "$state_dir" || fail "无法设置更新状态目录权限：$state_dir"
log_file="$state_dir/easyhostagent-macos-lifecycle.log"
[[ ! -L "$log_file" ]] || fail "生命周期日志不能是符号链接：$log_file"
touch "$log_file" || fail "无法创建生命周期日志：$log_file"
chmod 0600 "$log_file" || fail "无法设置生命周期日志权限：$log_file"
trap on_exit EXIT
log "开始：mode=$mode uid=$uid root=$root"
[[ -f "$env_file" && ! -L "$env_file" ]] || fail "请先运行 bash deploy.sh env"

# 安装、更新、卸载统一持有跨进程锁，避免同步、替换和 launchd 操作并发。
if [[ "$mode" == install || "$mode" == update || "$mode" == force-update || "$mode" == uninstall ]]; then
    if [[ "${EASYHOSTAGENT_UPDATE_LOCK_HELD:-0}" != 1 ]]; then
        stage="获取更新锁"
        command -v lockf >/dev/null 2>&1 || fail "系统缺少 lockf"
        lock_path="$state_dir/easyhostagent.macos-update.lock"
        [[ ! -L "$lock_path" ]] || fail "更新锁不能是符号链接：$lock_path"
        log "尝试获取独占更新锁：$lock_path"
        if lockf -k -t 0 "$lock_path" /usr/bin/env EASYHOSTAGENT_UPDATE_LOCK_HELD=1 /bin/bash "$0" "$@"; then
            exit 0
        else
            rc=$?
            fail "更新锁获取失败（exit=${rc}），另一个 EasyHostAgent 安装/更新/卸载任务正在运行；请稍后重试"
        fi
    fi
    log "已持有独占更新锁"
fi

# 配置采用逐键 KEY=VALUE 字面解析，不把用户配置当 Shell 代码执行。
read_config() {
    local target="$1" line key value seen=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        [[ "$key" == "$target" ]] || continue
        [[ "$seen" == 0 ]] || fail "配置重复：$target"
        seen=1
        value="${line#*=}"
        case "$value" in
            \"*\") value="${value:1:${#value}-2}" ;;
            \'*\') value="${value:1:${#value}-2}" ;;
        esac
        printf '%s' "$value"
    done < "$env_file"
}
stage="读取配置"
listen="$(read_config EASYHOSTAGENT_LISTEN_ADDRESS)"
[[ -n "$listen" ]] || listen=0.0.0.0:7018
[[ "$listen" =~ ^[0-9.]+:[0-9]+$ ]] || fail "EASYHOSTAGENT_LISTEN_ADDRESS 必须是 IPv4:端口"
port="${listen##*:}"
transport="$(read_config EASYHOSTAGENT_TRANSPORT)"
[[ -n "$transport" ]] || transport=https
case "$transport" in http|https) ;; *) fail "EASYHOSTAGENT_TRANSPORT 只能是 http 或 https" ;; esac
health_url="$transport://127.0.0.1:$port/v1/health"
stage="读取 Release 配置"
source "$root/deploy/lib/versions.sh"
deploy_load_versions "$root" || fail "无法读取统一 Release 版本配置"
release="$EASYHOSTAGENT_RELEASE"
[[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+[-.a-zA-Z0-9]*$ ]] || fail "macOS Release 标签格式不合法"
local_binary=""
if [[ "$mode" != force-update ]]; then
    local_binary="$(read_config EASYHOSTAGENT_MACOS_LOCAL_BINARY)"
fi
if [[ -n "$local_binary" ]]; then
    [[ "$local_binary" == /* && -f "$local_binary" && ! -L "$local_binary" ]] ||
        fail "本地二进制必须是普通绝对路径文件"
fi

run_agent() {
    EASYHOSTAGENT_PLATFORM=macos EASYHOSTAGENT_SOFTWARE_ROOT="$root" \
    EASYHOSTAGENT_DATA_DIR="$data_dir" EASYHOSTAGENT_LISTEN_ADDRESS="$listen" \
    EASYHOSTAGENT_TRANSPORT="$transport" "$binary" "$@"
}

probe_health() {
    local body
    if [[ "$transport" == https ]]; then
        if ! body="$(curl -kfsS --connect-timeout 2 --max-time 4 "$health_url" 2>&1)"; then
            log "健康接口请求失败：$body"
            return 1
        fi
    else
        if ! body="$(curl -fsS --connect-timeout 2 --max-time 4 "$health_url" 2>&1)"; then
            log "健康接口请求失败：$body"
            return 1
        fi
    fi
    if printf '%s' "$body" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"'; then
        return 0
    fi
    log "健康接口返回非 ready 状态：$body"
    return 1
}

wait_for_health() {
    local attempt
    for attempt in {1..30}; do
        if service_loaded && probe_health; then
            log "健康检查通过：launchd 已注册，$health_url 返回 status=ready"
            return 0
        fi
        if [[ "$attempt" -eq 1 || "$((attempt % 5))" -eq 0 ]]; then
            log "等待 Agent 就绪：第 $attempt/30 次，health=$health_url"
        fi
        sleep 1
    done
    return 1
}

stop_service() {
    stage="停止旧 LaunchAgent"
    if service_loaded; then
        log "发现旧服务，准备 bootout：$launch_label"
        if run_logged "launchctl bootout $launch_label" launchctl bootout "$launch_label"; then
            :
        elif service_loaded; then
            fail "launchctl bootout 失败，旧服务仍然注册；拒绝替换正在运行的二进制"
        else
            log "bootout 返回非零，但服务已从 launchd 域消失，继续检查"
        fi
        local attempt
        for attempt in {1..30}; do
            service_loaded || break
            sleep 0.5
        done
        if service_loaded; then
            fail "等待旧 LaunchAgent 注销超时"
        fi
        log "旧 LaunchAgent 已从 gui/$uid 域注销"
    else
        log "旧 LaunchAgent 当前未注册，跳过 bootout"
    fi
}

case "$mode" in
    pairing)
        [[ -f "$binary" ]] || fail "Agent 尚未安装"
        run_agent -pairing-code
        exit ;;
    identity)
        [[ -f "$binary" ]] || fail "Agent 尚未安装"
        run_agent -identity
        exit ;;
    status)
        stage="查询服务状态"
        [[ -f "$marker" && ! -L "$marker" && -f "$plist" && ! -L "$plist" && -x "$binary" && ! -L "$binary" ]] ||
            fail "Agent 尚未由当前安装器安装（缺少受管标识、plist 或可执行二进制）"
        run_logged "launchctl print $launch_label" launchctl print "$launch_label" ||
            fail "Agent 当前没有在 gui/$uid 登录用户域注册"
        stage="检查 HTTP 健康状态"
        if probe_health; then
            log "Agent 健康：$health_url 返回 status=ready"
            printf 'EasyHostAgent 正常运行：%s\n' "$health_url"
        else
            fail "launchd 已注册，但 HTTP 健康检查未就绪；请查看 $log_file 与 $data_dir/agent.stderr.log"
        fi
        exit ;;
esac

stage="检查安装归属与文件安全"
[[ -f "$env_file" && ! -L "$env_file" ]] || fail "配置文件不存在或不是普通文件"
for target in "$app_dir" "$app_dir/bin" "$plist_dir"; do
    [[ ! -L "$target" ]] || fail "不允许符号链接目录：$target"
done
[[ ! -L "$plist" && ! -L "$binary" && ! -L "$marker" ]] || fail "不允许符号链接安装文件"
if [[ ( -e "$binary" || -e "$plist" ) && ! -f "$marker" ]]; then
    fail "检测到非本安装器管理的 Agent 或 launchd 服务，拒绝接管"
fi
if [[ -e "$marker" ]]; then
    [[ -f "$marker" && "$(stat -f '%u:%Lp' "$marker")" == "$uid:600" ]] ||
        fail "安装标识归属或权限不可信"
fi

if [[ "$mode" == uninstall ]]; then
    [[ -f "$marker" ]] || fail "没有本安装器管理的 Agent"
    stop_service
    stage="卸载 Agent 文件"
    rm -f "$plist" "$binary" "$marker"
    log "已卸载 Agent 程序与 LaunchAgent，保留 $data_dir 中身份、配对及日志"
    exit
fi

stage="准备安装目录"
mkdir -p "$app_dir/bin" "$plist_dir" "$data_dir"
chmod 0700 "$data_dir"
tmp="$(mktemp -d)"
asset=easyhostagent-darwin-arm64
stage="下载或读取 Agent 二进制"
if [[ -n "$local_binary" ]]; then
    cp "$local_binary" "$tmp/$asset"
    [[ -f "$local_binary.sha256" ]] || fail "缺少本地同名校验文件 $local_binary.sha256"
    cp "$local_binary.sha256" "$tmp/$asset.sha256"
else
    base="https://github.com/CiBeDerORG/EasyHostAgent/releases/download/$release"
    run_logged "下载 macOS Agent 二进制" curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 -o "$tmp/$asset" "$base/$asset" ||
        fail "下载 macOS Agent 二进制失败"
    run_logged "下载 macOS Agent SHA-256" curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 -o "$tmp/$asset.sha256" "$base/$asset.sha256" ||
        fail "下载 macOS Agent 校验文件失败"
fi
stage="校验 Agent 二进制"
expected="$(awk 'NF >= 1 {print $1;exit}' "$tmp/$asset.sha256")"
actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "$actual" == "$expected" ]] || fail "macOS Agent SHA-256 校验失败"
run_logged "识别 Agent 二进制架构" file "$tmp/$asset" || fail "无法识别 Agent 二进制"
file "$tmp/$asset" | grep -q "Mach-O.*arm64" || fail "二进制不是 macOS ARM64 可执行程序"
chmod 0700 "$tmp/$asset"
stage="Agent 配置自检"
EASYHOSTAGENT_PLATFORM=macos EASYHOSTAGENT_SOFTWARE_ROOT="$root" \
EASYHOSTAGENT_DATA_DIR="$data_dir" EASYHOSTAGENT_LISTEN_ADDRESS="$listen" \
EASYHOSTAGENT_TRANSPORT="$transport" "$tmp/$asset" -check-config ||
    fail "Agent 原生配置自检失败"

# plist 字符串 XML 转义，禁止路径含特殊字符时注入新的 plist 键。
xml() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
xml_bin="$(xml "$binary")"
xml_data="$(xml "$data_dir")"
xml_root="$(xml "$root")"
xml_listen="$(xml "$listen")"
xml_transport="$(xml "$transport")"
xml_out="$(xml "$data_dir/agent.stdout.log")"
xml_err="$(xml "$data_dir/agent.stderr.log")"
cat > "$tmp/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$xml_bin</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>EASYHOSTAGENT_PLATFORM</key><string>macos</string>
    <key>EASYHOSTAGENT_SOFTWARE_ROOT</key><string>$xml_root</string>
    <key>EASYHOSTAGENT_DATA_DIR</key><string>$xml_data</string>
    <key>EASYHOSTAGENT_LISTEN_ADDRESS</key><string>$xml_listen</string>
    <key>EASYHOSTAGENT_TRANSPORT</key><string>$xml_transport</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$xml_out</string>
  <key>StandardErrorPath</key><string>$xml_err</string>
</dict>
</plist>
EOF
stage="校验 LaunchAgent plist"
run_logged "plutil -lint 临时 plist" plutil -lint "$tmp/agent.plist" || fail "生成的 launchd plist 不合法"

had_previous=0
if [[ -f "$binary" ]]; then
    cp -p "$binary" "$tmp/easyhostagent.previous"
    had_previous=1
    log "已保存旧二进制用于启动失败回滚"
fi

if [[ "$no_start" != --no-start ]]; then
    stop_service
fi

stage="原子替换 Agent 二进制与 plist"
cp "$tmp/$asset" "$app_dir/bin/.easyhostagent.next"
chmod 0700 "$app_dir/bin/.easyhostagent.next"
mv -f "$app_dir/bin/.easyhostagent.next" "$binary"
cp "$tmp/agent.plist" "$plist.tmp"
chmod 0600 "$plist.tmp"
mv -f "$plist.tmp" "$plist"
printf 'managed by deploy macOS phase1\n' > "$marker"
chmod 0600 "$marker"
log "二进制与 plist 已原子替换：binary=$binary plist=$plist"

if [[ "$no_start" == --no-start ]]; then
    log "因 --no-start 跳过 launchd 注册和健康检查"
    echo "Agent 已安装并生成 plist，但因 --no-start 未注册 launchd"
    exit
fi

stage="注册 LaunchAgent"
run_logged "launchctl bootstrap gui/$uid $plist" launchctl bootstrap "gui/$uid" "$plist" ||
    fail "launchctl bootstrap 失败；请检查本日志中的 launchctl 输出和 GUI/$uid 域状态"
stage="启动 LaunchAgent"
run_logged "launchctl kickstart $launch_label" launchctl kickstart "$launch_label" ||
    fail "launchctl kickstart 失败"

stage="等待服务注册与 HTTP 健康检查"
if ! wait_for_health; then
    log "新版本在 30 秒内未就绪，开始收集诊断并尝试回滚"
    collect_diagnostics
    if [[ "$had_previous" == 1 ]]; then
        stage="回滚旧 Agent"
        stop_service || true
        cp -p "$tmp/easyhostagent.previous" "$app_dir/bin/.easyhostagent.rollback"
        chmod 0700 "$app_dir/bin/.easyhostagent.rollback"
        mv -f "$app_dir/bin/.easyhostagent.rollback" "$binary"
        log "已恢复更新前二进制，重新注册旧版本"
        if run_logged "回滚 launchctl bootstrap" launchctl bootstrap "gui/$uid" "$plist" &&
           run_logged "回滚 launchctl kickstart" launchctl kickstart "$launch_label" &&
           wait_for_health; then
            log "旧版本回滚成功并通过健康检查"
        else
            log "ERROR：旧版本回滚后仍未就绪，需要人工检查 launchd 和 Agent stderr"
        fi
    else
        log "首次安装没有旧二进制可回滚"
    fi
    fail "Agent 启动失败或 HTTP 健康检查未通过；详细日志：$log_file"
fi

stage="完成"
run_logged "最终 launchctl 服务状态" launchctl print "$launch_label" ||
    fail "健康检查通过但 launchd 服务状态无法读取"
log "EasyHostAgent macOS 启动成功：transport=$transport listen=$listen health=$health_url"
echo "EasyHostAgent macOS 已安装并通过健康检查：$health_url"
echo "生命周期日志：$log_file"
echo "Agent 标准错误日志：$data_dir/agent.stderr.log"
echo "身份配对命令：bash deploy.sh easyhostagent pairing"
