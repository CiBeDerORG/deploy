#!/bin/sh
set -eu

ETC_DIR="/etc/easytier"
CONFIG_DIR="$ETC_DIR/config"
MACHINE_ID_FILE="$ETC_DIR/machine-id"
UCI_FILE="/etc/config/easytier"
INIT_FILE="/etc/init.d/easytier"
CORE_BIN="/usr/bin/easytier-core"
CLI_BIN="/usr/bin/easytier-cli"

CONFIG_SERVER="${EASYTIER_CONFIG_SERVER:-}"
EASYTIER_PORT="${EASYTIER_PORT:-7005}"
EASYTIER_RPC_PORT="${EASYTIER_RPC_PORT:-7006}"
VERSION="${EASYTIER_VERSION:-}"
GH_PROXY="${EASYTIER_GH_PROXY:-}"
FORCE_ARCH="${EASYTIER_ARCH:-}"

usage() {
    cat <<'USAGE'
EasyTier OpenWrt Web-managed installer

Usage:
  sh install.sh --config-server udp://SERVER:PORT/USER
  sh install.sh                         # update/reinstall using saved Config Server

Options:
  --config-server URL   Web Config Server, e.g. udp://1.2.3.4:7008/admin
  --port PORT           EasyTier TCP/UDP listener port (default: 7005)
  --rpc-port PORT       EasyTier RPC portal port on localhost (default: 7006)
  --version VERSION     Pin a release, e.g. v2.6.4 (default: latest)
  --gh-proxy PREFIX     Optional GitHub download proxy prefix
  --arch ARCH           Override release arch (x86_64/aarch64/armv7hf/mips/mipsel/...)
  -h, --help            Show help

Environment variables:
  EASYTIER_CONFIG_SERVER EASYTIER_PORT EASYTIER_RPC_PORT EASYTIER_VERSION EASYTIER_GH_PROXY EASYTIER_ARCH
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --config-server) [ $# -ge 2 ] || fail "--config-server 缺少参数"; CONFIG_SERVER="$2"; shift 2 ;;
        --port) [ $# -ge 2 ] || fail "--port 缺少参数"; EASYTIER_PORT="$2"; shift 2 ;;
        --rpc-port) [ $# -ge 2 ] || fail "--rpc-port 缺少参数"; EASYTIER_RPC_PORT="$2"; shift 2 ;;
        --version) [ $# -ge 2 ] || fail "--version 缺少参数"; VERSION="$2"; shift 2 ;;
        --gh-proxy) [ $# -ge 2 ] || fail "--gh-proxy 缺少参数"; GH_PROXY="$2"; shift 2 ;;
        --arch) [ $# -ge 2 ] || fail "--arch 缺少参数"; FORCE_ARCH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || fail "请使用 root 执行"
if [ ! -f /etc/openwrt_release ]; then
    grep -qi openwrt /etc/os-release 2>/dev/null || fail "当前系统不是 OpenWrt"
fi

install_deps() {
    need=""
    command -v curl >/dev/null 2>&1 || need="$need curl"
    command -v unzip >/dev/null 2>&1 || need="$need unzip"
    [ -z "$need" ] && return 0

    if command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install ca-bundle $need || opkg install $need
    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add ca-bundle $need
    else
        fail "缺少依赖:$need，且未找到 opkg/apk"
    fi
}

ensure_tun() {
    [ -c /dev/net/tun ] && return 0
    modprobe tun >/dev/null 2>&1 || true
    [ -c /dev/net/tun ] && return 0

    log "未检测到 /dev/net/tun，尝试安装 kmod-tun..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install kmod-tun || true
    else
        apk update
        apk add kmod-tun || true
    fi
    modprobe tun >/dev/null 2>&1 || true
    [ -c /dev/net/tun ] || fail "无法提供 /dev/net/tun，请检查 OpenWrt 内核/TUN 支持"
}

detect_arch() {
    [ -n "$FORCE_ARCH" ] && { printf '%s\n' "$FORCE_ARCH"; return; }
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64|*armv8*) arch=aarch64 ;;
        armv7*|*armv7*)
            arch=armv7
            grep -qi '^Features.*half' /proc/cpuinfo 2>/dev/null && arch=armv7hf || true
            ;;
        armv6*|arm*)
            arch=arm
            grep -qi '^Features.*half' /proc/cpuinfo 2>/dev/null && arch=armhf || true
            ;;
        mipsel*|mipsle*) arch=mipsel ;;
        mips*) arch=mips ;;
        riscv64*) arch=riscv64 ;;
        loongarch64*) arch=loongarch64 ;;
        *) fail "不支持的 CPU 架构: $(uname -m)，可用 --arch 手动指定" ;;
    esac
    printf '%s\n' "$arch"
}

latest_version() {
    json="$(curl -fsSL https://api.github.com/repos/EasyTier/EasyTier/releases/latest)" || fail "无法获取 EasyTier 最新版本"
    printf '%s\n' "$json" | grep '"tag_name"' | head -n 1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

prepare_identity() {
    mkdir -p "$ETC_DIR" "$CONFIG_DIR"
    chmod 700 "$ETC_DIR" "$CONFIG_DIR"
    [ -s "$MACHINE_ID_FILE" ] && return 0

    if [ -s /etc/machine-id ]; then
        tr -cd 'A-Za-z0-9._-' < /etc/machine-id > "$MACHINE_ID_FILE"
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        tr -d '-\r\n' < /proc/sys/kernel/random/uuid > "$MACHINE_ID_FILE"
    else
        printf '%s' "$(date +%s)-$(uname -n)-$$" | md5sum | awk '{print $1}' > "$MACHINE_ID_FILE"
    fi
    [ -s "$MACHINE_ID_FILE" ] || fail "machine-id 生成失败"
    chmod 600 "$MACHINE_ID_FILE"
}

saved_config_server() {
    command -v uci >/dev/null 2>&1 || return 0
    uci -q get easytier.main.config_server 2>/dev/null || true
}

download_core() {
    arch="$(detect_arch)"
    if [ -n "$VERSION" ]; then
        ver="$VERSION"
    else
        ver="$(latest_version)"
    fi
    [ -n "$ver" ] || fail "无法确定 EasyTier 版本"
    case "$ver" in v*) ;; *) ver="v$ver" ;; esac

    if [ -n "$VERSION" ]; then
        base="https://github.com/EasyTier/EasyTier/releases/download/$ver/easytier-linux-${arch}-${ver}.zip"
    else
        base="https://github.com/EasyTier/EasyTier/releases/latest/download/easytier-linux-${arch}-${ver}.zip"
    fi
    url="${GH_PROXY}${base}"
    tmp="$(mktemp -d /tmp/easytier-openwrt.XXXXXX)"
    trap 'rm -rf "$tmp"' 0 1 2 15

    log "下载 EasyTier $ver ($arch)..."
    curl -fL "$url" -o "$tmp/easytier.zip"
    unzip -oq "$tmp/easytier.zip" -d "$tmp"
    src="$tmp/easytier-linux-${arch}"
    [ -x "$src/easytier-core" ] || fail "下载包中未找到 easytier-core"
    [ -x "$src/easytier-cli" ] || fail "下载包中未找到 easytier-cli"
    "$src/easytier-core" --version >/dev/null 2>&1 || fail "二进制无法运行，请检查 CPU 架构"

    cp "$src/easytier-core" "$CORE_BIN"
    cp "$src/easytier-cli" "$CLI_BIN"
    chmod 0755 "$CORE_BIN" "$CLI_BIN"
    printf '%s\n' "$ver" > "$ETC_DIR/version"

    rm -rf "$tmp"
    trap - 0 1 2 15
}

validate_port() {
    name="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*) fail "$name 必须是数字端口，当前值: ${value:-<空>}" ;;
    esac
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || fail "$name 必须在 1-65535 范围内，当前值: $value"
}

write_uci() {
    command -v uci >/dev/null 2>&1 || fail "未找到 uci"
    uci -q delete easytier.main || true
    uci set easytier.main=easytier
    uci set easytier.main.enabled='1'
    uci set easytier.main.config_server="$CONFIG_SERVER"
    uci set easytier.main.listener_port="$EASYTIER_PORT"
    uci set easytier.main.rpc_port="$EASYTIER_RPC_PORT"
    uci set easytier.main.config_dir="$CONFIG_DIR"
    uci set easytier.main.machine_id_file="$MACHINE_ID_FILE"
    uci commit easytier
    chmod 600 "$UCI_FILE"
}

write_service() {
    cat > "$INIT_FILE" <<'INIT'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
    local enabled config_server listener_port rpc_port config_dir machine_id_file machine_id
    config_load easytier
    config_get_bool enabled main enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get config_server main config_server
    config_get listener_port main listener_port 7005
    config_get rpc_port main rpc_port 7006
    config_get config_dir main config_dir /etc/easytier/config
    config_get machine_id_file main machine_id_file /etc/easytier/machine-id
    [ -x /usr/bin/easytier-core ] || return 1
    [ -n "$config_server" ] || return 1
    [ -s "$machine_id_file" ] || return 1
    machine_id="$(cat "$machine_id_file")"
    mkdir -p "$config_dir"

    procd_open_instance
    procd_set_param command /usr/bin/easytier-core \
        --config-server "$config_server" \
        --config-dir "$config_dir" \
        --machine-id "$machine_id" \
        --listeners "tcp://0.0.0.0:${listener_port},udp://0.0.0.0:${listener_port}" \
        --rpc-portal "$rpc_port"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger easytier
}
INIT
    chmod 0755 "$INIT_FILE"
}

install_deps
ensure_tun
prepare_identity

if [ -z "$CONFIG_SERVER" ]; then
    CONFIG_SERVER="$(saved_config_server)"
fi
validate_port EASYTIER_PORT "$EASYTIER_PORT"
validate_port EASYTIER_RPC_PORT "$EASYTIER_RPC_PORT"
[ "$EASYTIER_PORT" -ne "$EASYTIER_RPC_PORT" ] || fail "EASYTIER_PORT 与 EASYTIER_RPC_PORT 不能重复"
[ -n "$CONFIG_SERVER" ] || fail "请指定 --config-server，例如 udp://公网服务器IP:7008/admin"
case "$CONFIG_SERVER" in udp://*|tcp://*) ;; *) fail "Config Server 必须以 udp:// 或 tcp:// 开头" ;; esac

download_core
write_uci
write_service

"$INIT_FILE" enable
"$INIT_FILE" restart
sleep 2

if ! pidof easytier-core >/dev/null 2>&1; then
    logread -e easytier 2>/dev/null | tail -n 40 || true
    fail "EasyTier Core 启动失败"
fi

log ""
log "=================================================="
log " EasyTier OpenWrt Web-managed 安装完成"
log "=================================================="
log "EasyTier Port: $EASYTIER_PORT (TCP/UDP)"
log "RPC Port:      127.0.0.1:$EASYTIER_RPC_PORT"
log "Config Server: $CONFIG_SERVER"
log "Machine ID:    $(cat "$MACHINE_ID_FILE")"
log "Config Dir:    $CONFIG_DIR"
log ""
log "Web 下发的 .toml 配置会持久化到 $CONFIG_DIR。"
log "网络名、密钥、虚拟 IP/DHCP、Peer、子网代理等后续直接在 Web Console 设置。"
log "Listener 固定为 TCP/UDP $EASYTIER_PORT，RPC 固定为本机 $EASYTIER_RPC_PORT。"
log ""
log "常用命令："
log "  /etc/init.d/easytier status"
log "  /etc/init.d/easytier restart"
log "  logread -e easytier"
