#!/usr/bin/env bash
# macOS 原生 Agent：普通登录用户安装 launchd LaunchAgent；Docker Desktop 可选。
set -euo pipefail
umask 077
fail() { printf 'EasyHostAgent macOS：%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "目前只支持 macOS Apple Silicon (arm64)"
[[ "$(id -u)" -ne 0 ]] || fail "请用 Mac 当前登录用户执行，不要 sudo"
mode="${1:-install}"
root="${2:-/opt/software}"
no_start="${3:-}"
case "$mode" in install|update|uninstall|status|pairing|identity) ;; *) fail "命令只支持 install/update/uninstall/status/pairing/identity" ;; esac
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
[[ -f "$env_file" && ! -L "$env_file" ]] || fail "请先运行 bash deploy.sh env"

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
listen="$(read_config EASYHOSTAGENT_LISTEN_ADDRESS)"
[[ -n "$listen" ]] || listen=0.0.0.0:7018
[[ "$listen" =~ ^[0-9.]+:[0-9]+$ ]] || fail "EASYHOSTAGENT_LISTEN_ADDRESS 必须是 IPv4:端口"
transport="$(read_config EASYHOSTAGENT_TRANSPORT)"
[[ -n "$transport" ]] || transport=https
case "$transport" in http|https) ;; *) fail "EASYHOSTAGENT_TRANSPORT 只能是 http 或 https" ;; esac
# Linux/fnOS 与 macOS 共用 Release 标签；此处按 macOS 平台下载 darwin/arm64 资产。
release="$(read_config EASYHOSTAGENT_RELEASE)"
[[ -n "$release" ]] || release=v0.1.0-deploy-manifest-lifecycle.dev
[[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+[-.a-zA-Z0-9]*$ ]] || fail "macOS Release 标签格式不合法"
local_binary="$(read_config EASYHOSTAGENT_MACOS_LOCAL_BINARY)"
if [[ -n "$local_binary" ]]; then
    [[ "$local_binary" == /* && -f "$local_binary" && ! -L "$local_binary" ]] ||
        fail "本地二进制必须是普通绝对路径文件"
fi
run_agent() {
    EASYHOSTAGENT_PLATFORM=macos EASYHOSTAGENT_SOFTWARE_ROOT="$root" \
    EASYHOSTAGENT_DATA_DIR="$data_dir" EASYHOSTAGENT_LISTEN_ADDRESS="$listen" \
    EASYHOSTAGENT_TRANSPORT="$transport" "$binary" "$@"
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
        launchctl print "$launch_label" || fail "Agent 当前没有作为登录用户服务运行"
        exit ;;
esac

# 禁止接管其他软件安装的同名服务与二进制。
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
    if launchctl print "$launch_label" >/dev/null 2>&1; then
        launchctl bootout "$launch_label" || fail "停止 LaunchAgent 失败"
    fi
    rm -f "$plist" "$binary" "$marker"
    echo "已卸载 Agent 程序与 LaunchAgent，保留 $data_dir 中身份、配对及日志"
    exit
fi
mkdir -p "$app_dir/bin" "$plist_dir" "$data_dir"
chmod 0700 "$data_dir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
asset=easyhostagent-darwin-arm64
if [[ -n "$local_binary" ]]; then
    cp "$local_binary" "$tmp/$asset"
    [[ -f "$local_binary.sha256" ]] || fail "缺少本地同名校验文件 $local_binary.sha256"
    cp "$local_binary.sha256" "$tmp/$asset.sha256"
else
    base="https://github.com/CiBeDerORG/EasyHostAgent/releases/download/$release"
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 -o "$tmp/$asset" "$base/$asset" ||
        fail "下载 macOS Agent 二进制失败"
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 -o "$tmp/$asset.sha256" "$base/$asset.sha256" ||
        fail "下载 macOS Agent 校验文件失败"
fi
expected="$(awk 'NF >= 1 {print $1;exit}' "$tmp/$asset.sha256")"
actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "$actual" == "$expected" ]] || fail "macOS Agent SHA-256 校验失败"
file "$tmp/$asset" | grep -q "Mach-O.*arm64" || fail "二进制不是 macOS ARM64 可执行程序"
chmod 0700 "$tmp/$asset"
EASYHOSTAGENT_PLATFORM=macos EASYHOSTAGENT_SOFTWARE_ROOT="$root" \
EASYHOSTAGENT_DATA_DIR="$data_dir" EASYHOSTAGENT_LISTEN_ADDRESS="$listen" \
EASYHOSTAGENT_TRANSPORT="$transport" "$tmp/$asset" -check-config >/dev/null ||
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
plutil -lint "$tmp/agent.plist" >/dev/null || fail "生成的 launchd plist 不合法"
# 只有完整验证后才替换程序。此阶段 release 为滚动开发版，不是正式签名发行版。
cp "$tmp/$asset" "$app_dir/bin/.easyhostagent.next"
chmod 0700 "$app_dir/bin/.easyhostagent.next"
mv -f "$app_dir/bin/.easyhostagent.next" "$binary"
cp "$tmp/agent.plist" "$plist.tmp"
chmod 0600 "$plist.tmp"
mv -f "$plist.tmp" "$plist"
printf 'managed by deploy macOS phase1\n' > "$marker"
chmod 0600 "$marker"
if [[ "$no_start" == --no-start ]]; then
    echo "Agent 已安装并生成 plist，但因 --no-start 未注册 launchd"
    exit
fi
if launchctl print "$launch_label" >/dev/null 2>&1; then
    launchctl bootout "$launch_label" || fail "旧 LaunchAgent 停止失败"
fi
launchctl bootstrap "gui/$uid" "$plist" ||
    fail "启动 LaunchAgent 失败；需要登录图形用户会话，可运行 launchctl bootstrap gui/$uid '$plist'"
launchctl kickstart -k "$launch_label" || fail "LaunchAgent 未成功启动"
echo "EasyHostAgent macOS 已安装，传输：${transport}，监听 ${listen}"
echo "身份配对命令：bash deploy.sh easyhostagent pairing"
