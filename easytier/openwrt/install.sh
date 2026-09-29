#!/bin/sh
set -eu

ETC_DIR="/etc/easytier"
CONFIG_DIR="$ETC_DIR/config"
MACHINE_ID_FILE="$ETC_DIR/machine-id"
VERSION_FILE="$ETC_DIR/version"
UCI_FILE="/etc/config/easytier"
INIT_FILE="/etc/init.d/easytier"
CORE_BIN="/usr/bin/easytier-core"
CLI_BIN="/usr/bin/easytier-cli"

CONFIG_SERVER="${EASYTIER_CONFIG_SERVER:-}"
LISTENER_PORT="${EASYTIER_PORT:-7005}"
RPC_PORT="${EASYTIER_RPC_PORT:-7006}"
TUN_NAME="${EASYTIER_TUN_NAME:-tun0}"
AUTO_FIREWALL="${EASYTIER_AUTO_FIREWALL:-1}"
OPEN_WAN_LISTENER="${EASYTIER_OPEN_WAN_LISTENER:-0}"
VERSION="${EASYTIER_VERSION:-}"
GH_PROXY="${EASYTIER_GH_PROXY:-}"
FORCE_ARCH="${EASYTIER_ARCH:-}"

TMP_DIR=""
NEW_CORE=""
NEW_CLI=""
NEW_VERSION=""
CORE_BAK=""
CLI_BAK=""
REPLACE_ACTIVE=0
HAD_CORE=0
HAD_CLI=0

usage() {
    cat <<'USAGE'
EasyTier OpenWrt Web-managed installer

Usage:
  sh install.sh --config-server udp://SERVER:7008/USER
  sh install.sh

Options:
  --config-server URL    Web Config Server，例如 udp://1.2.3.4:7008/admin
  --port PORT            EasyTier Web 配置中约定的监听端口，默认 7005
  --rpc-port PORT        本机 RPC Portal 端口，默认 7006
  --tun-name NAME        Web 配置中约定的 TUN 名称，默认 tun0
  --open-wan-listener    在 OpenWrt WAN 防火墙放行 PORT 的 TCP/UDP
  --no-firewall          不自动配置 EasyTier -> LAN / LAN -> EasyTier 防火墙
  --version VERSION      固定版本，例如 v2.6.4；默认 latest
  --gh-proxy PREFIX      GitHub 下载代理前缀
  --arch ARCH            手动指定 release 架构
  -h, --help             显示帮助

Environment:
  EASYTIER_CONFIG_SERVER
  EASYTIER_PORT
  EASYTIER_RPC_PORT
  EASYTIER_TUN_NAME
  EASYTIER_AUTO_FIREWALL
  EASYTIER_OPEN_WAN_LISTENER
  EASYTIER_VERSION
  EASYTIER_GH_PROXY
  EASYTIER_ARCH

注意：
  Web Config Server 模式下，网络实例的 Listener 和 dev_name 由 Web 下发的 TOML 决定。
  本脚本不会用 easytier-core 的普通网络 CLI 参数覆盖 Web 配置。
  为使 OpenWrt 防火墙规则准确生效，请在 Web 中设置：
    Listener: tcp://0.0.0.0:7005, udp://0.0.0.0:7005
    dev_name: tun0
  如果你使用其它端口/TUN 名，请同时用 --port / --tun-name 告诉本脚本。
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup_files() {
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}

on_exit() {
    rc=$?
    trap - EXIT INT TERM

    if [ "$rc" -ne 0 ] && [ "$REPLACE_ACTIVE" = "1" ]; then
        rollback_binaries || true
    fi

    cleanup_files
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --config-server) [ $# -ge 2 ] || fail "--config-server 缺少参数"; CONFIG_SERVER="$2"; shift 2 ;;
        --port) [ $# -ge 2 ] || fail "--port 缺少参数"; LISTENER_PORT="$2"; shift 2 ;;
        --rpc-port) [ $# -ge 2 ] || fail "--rpc-port 缺少参数"; RPC_PORT="$2"; shift 2 ;;
        --tun-name) [ $# -ge 2 ] || fail "--tun-name 缺少参数"; TUN_NAME="$2"; shift 2 ;;
        --open-wan-listener) OPEN_WAN_LISTENER=1; shift ;;
        --no-firewall) AUTO_FIREWALL=0; shift ;;
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

validate_port() {
    name="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*) fail "$name 必须是数字端口，当前值: ${value:-<空>}" ;;
    esac
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || fail "$name 必须在 1-65535，当前值: $value"
}

validate_bool() {
    name="$1"
    value="$2"
    case "$value" in
        0|1) ;;
        *) fail "$name 只能是 0 或 1，当前值: $value" ;;
    esac
}

validate_input() {
    validate_port EASYTIER_PORT "$LISTENER_PORT"
    validate_port EASYTIER_RPC_PORT "$RPC_PORT"
    validate_bool EASYTIER_AUTO_FIREWALL "$AUTO_FIREWALL"
    validate_bool EASYTIER_OPEN_WAN_LISTENER "$OPEN_WAN_LISTENER"

    [ "$LISTENER_PORT" -ne "$RPC_PORT" ] || fail "EasyTier Listener 与 RPC 端口不能重复"
    case "$TUN_NAME" in
        ''|*[!A-Za-z0-9_.:-]*) fail "TUN 名称包含非法字符: $TUN_NAME" ;;
    esac
    [ "${#TUN_NAME}" -le 15 ] || fail "Linux 网卡名最长 15 字符: $TUN_NAME"

    [ -n "$CONFIG_SERVER" ] || return 0
    case "$CONFIG_SERVER" in
        udp://*|tcp://*|ws://*|wss://*) ;;
        *) fail "Config Server 必须以 udp://、tcp://、ws:// 或 wss:// 开头" ;;
    esac
}

install_deps() {
    need=""
    command -v curl >/dev/null 2>&1 || need="$need curl"
    command -v unzip >/dev/null 2>&1 || need="$need unzip"
    command -v uci >/dev/null 2>&1 || fail "未找到 uci，当前系统不像完整 OpenWrt"

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
    elif command -v apk >/dev/null 2>&1; then
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
    json="$(curl -fsSL https://api.github.com/repos/EasyTier/EasyTier/releases/latest)" ||
        fail "无法获取 EasyTier 最新版本"

    printf '%s\n' "$json" |
        grep '"tag_name"' |
        head -n 1 |
        sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
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
    uci -q get easytier.main.config_server 2>/dev/null || true
}

download_release() {
    arch="$(detect_arch)"

    if [ -n "$VERSION" ]; then
        ver="$VERSION"
    else
        ver="$(latest_version)"
    fi

    [ -n "$ver" ] || fail "无法确定 EasyTier 版本"
    case "$ver" in v*) ;; *) ver="v$ver" ;; esac

    base="https://github.com/EasyTier/EasyTier/releases/download/$ver/easytier-linux-${arch}-${ver}.zip"
    url="${GH_PROXY}${base}"

    TMP_DIR="$(mktemp -d /tmp/easytier-openwrt.XXXXXX)"
    log "下载 EasyTier $ver ($arch)..."
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$TMP_DIR/easytier.zip"
    unzip -oq "$TMP_DIR/easytier.zip" -d "$TMP_DIR"

    src="$TMP_DIR/easytier-linux-${arch}"
    NEW_CORE="$src/easytier-core"
    NEW_CLI="$src/easytier-cli"
    NEW_VERSION="$ver"

    [ -x "$NEW_CORE" ] || fail "下载包中未找到 easytier-core"
    [ -x "$NEW_CLI" ] || fail "下载包中未找到 easytier-cli"
    "$NEW_CORE" --version >/dev/null 2>&1 || fail "easytier-core 无法运行，请检查 CPU 架构"
    "$NEW_CLI" --version >/dev/null 2>&1 || fail "easytier-cli 无法运行，请检查 CPU 架构"
}

write_uci() {
    uci -q delete easytier.main || true
    uci set easytier.main=easytier
    uci set easytier.main.enabled='1'
    uci set easytier.main.config_server="$CONFIG_SERVER"
    uci set easytier.main.listener_port="$LISTENER_PORT"
    uci set easytier.main.rpc_port="$RPC_PORT"
    uci set easytier.main.tun_name="$TUN_NAME"
    uci set easytier.main.auto_firewall="$AUTO_FIREWALL"
    uci set easytier.main.open_wan_listener="$OPEN_WAN_LISTENER"
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
    local enabled config_server config_dir machine_id_file machine_id rpc_port

    config_load easytier
    config_get_bool enabled main enabled 1
    [ "$enabled" -eq 1 ] || return 0

    config_get config_server main config_server
    config_get config_dir main config_dir /etc/easytier/config
    config_get machine_id_file main machine_id_file /etc/easytier/machine-id
    config_get rpc_port main rpc_port 7006

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
        --rpc-portal "$rpc_port"
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="65535 65535"
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

configure_firewall() {
    [ "$AUTO_FIREWALL" = "1" ] || {
        log "跳过 OpenWrt 防火墙自动配置。"
        return 0
    }

    command -v fw4 >/dev/null 2>&1 || warn "未检测到 fw4；将仍写入标准 UCI 防火墙配置。"

    # 直接按 TUN 设备匹配，不创建/重载 OpenWrt network interface，避免远程安装时影响 WAN/LAN。
    uci -q delete firewall.easytierzone || true
    uci set firewall.easytierzone='zone'
    uci set firewall.easytierzone.name='EasyTier'
    uci set firewall.easytierzone.input='ACCEPT'
    uci set firewall.easytierzone.output='ACCEPT'
    uci set firewall.easytierzone.forward='ACCEPT'
    uci set firewall.easytierzone.mtu_fix='1'
    uci add_list firewall.easytierzone.device="$TUN_NAME"

    uci -q delete firewall.easytier_to_lan || true
    uci set firewall.easytier_to_lan='forwarding'
    uci set firewall.easytier_to_lan.src='EasyTier'
    uci set firewall.easytier_to_lan.dest='lan'

    uci -q delete firewall.lan_to_easytier || true
    uci set firewall.lan_to_easytier='forwarding'
    uci set firewall.lan_to_easytier.src='lan'
    uci set firewall.lan_to_easytier.dest='EasyTier'

    uci -q delete firewall.easytier_listener_wan || true
    if [ "$OPEN_WAN_LISTENER" = "1" ]; then
        uci set firewall.easytier_listener_wan='rule'
        uci set firewall.easytier_listener_wan.name='Allow-EasyTier-Listener'
        uci set firewall.easytier_listener_wan.src='wan'
        uci set firewall.easytier_listener_wan.proto='tcp udp'
        uci set firewall.easytier_listener_wan.dest_port="$LISTENER_PORT"
        uci set firewall.easytier_listener_wan.target='ACCEPT'
    fi

    uci commit firewall

    if [ -x /etc/init.d/firewall ]; then
        /etc/init.d/firewall reload >/dev/null 2>&1 ||
            warn "防火墙 reload 失败，请稍后手动执行 /etc/init.d/firewall reload"
    fi

    # OpenWrt 路由系统一般已开启；这里确保当前运行时开启。
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
}

stage_binaries() {
    core_new="$CORE_BIN.new.$$"
    cli_new="$CLI_BIN.new.$$"

    cp "$NEW_CORE" "$core_new"
    cp "$NEW_CLI" "$cli_new"
    chmod 0755 "$core_new" "$cli_new"

    "$core_new" --version >/dev/null 2>&1 || {
        rm -f "$core_new" "$cli_new"
        fail "暂存的 easytier-core 校验失败"
    }

    "$cli_new" --version >/dev/null 2>&1 || {
        rm -f "$core_new" "$cli_new"
        fail "暂存的 easytier-cli 校验失败"
    }

    printf '%s\n%s\n' "$core_new" "$cli_new"
}

stop_service() {
    if [ -x "$INIT_FILE" ]; then
        "$INIT_FILE" stop >/dev/null 2>&1 || true
    fi

    i=0
    while pidof easytier-core >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done

    if pidof easytier-core >/dev/null 2>&1; then
        warn "正常停止超时，终止旧 easytier-core"
        killall easytier-core >/dev/null 2>&1 || true
        sleep 1
    fi
}

replace_binaries() {
    core_new="$1"
    cli_new="$2"

    CORE_BAK="$CORE_BIN.bak"
    CLI_BAK="$CLI_BIN.bak"
    HAD_CORE=0
    HAD_CLI=0
    [ ! -e "$CORE_BIN" ] || HAD_CORE=1
    [ ! -e "$CLI_BIN" ] || HAD_CLI=1

    rm -f "$CORE_BAK" "$CLI_BAK"
    REPLACE_ACTIVE=1

    [ "$HAD_CORE" = "0" ] || mv "$CORE_BIN" "$CORE_BAK"
    [ "$HAD_CLI" = "0" ] || mv "$CLI_BIN" "$CLI_BAK"

    mv "$core_new" "$CORE_BIN"
    mv "$cli_new" "$CLI_BIN"
    chmod 0755 "$CORE_BIN" "$CLI_BIN"
}

rollback_binaries() {
    warn "安装/更新失败，回滚 EasyTier 二进制..."

    if [ "$HAD_CORE" = "1" ] && [ -e "$CORE_BAK" ]; then
        rm -f "$CORE_BIN"
        mv "$CORE_BAK" "$CORE_BIN"
    elif [ "$HAD_CORE" = "0" ]; then
        rm -f "$CORE_BIN"
    fi

    if [ "$HAD_CLI" = "1" ] && [ -e "$CLI_BAK" ]; then
        rm -f "$CLI_BIN"
        mv "$CLI_BAK" "$CLI_BIN"
    elif [ "$HAD_CLI" = "0" ]; then
        rm -f "$CLI_BIN"
    fi

    REPLACE_ACTIVE=0

    if [ "$HAD_CORE" = "1" ] && [ -x "$INIT_FILE" ] && [ -x "$CORE_BIN" ]; then
        "$INIT_FILE" start >/dev/null 2>&1 || true
    fi
}

start_and_verify() {
    "$INIT_FILE" enable
    "$INIT_FILE" restart

    i=0
    while [ "$i" -lt 12 ]; do
        if pidof easytier-core >/dev/null 2>&1; then
            # RPC manager 可以在没有 Web 网络实例时先启动，所以这里只校验 Core 进程。
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    return 1
}

validate_input
install_deps
ensure_tun
prepare_identity

if [ -z "$CONFIG_SERVER" ]; then
    CONFIG_SERVER="$(saved_config_server)"
fi
[ -n "$CONFIG_SERVER" ] || fail "请指定 --config-server，例如 udp://公网服务器IP:7008/admin"
case "$CONFIG_SERVER" in
    udp://*|tcp://*|ws://*|wss://*) ;;
    *) fail "Config Server 必须以 udp://、tcp://、ws:// 或 wss:// 开头" ;;
esac

download_release

# 在停止旧服务前先把配置文件和新二进制全部准备好，尽量缩短中断时间。
write_uci
write_service
configure_firewall

staged="$(stage_binaries)"
core_new="$(printf '%s\n' "$staged" | sed -n '1p')"
cli_new="$(printf '%s\n' "$staged" | sed -n '2p')"

stop_service
replace_binaries "$core_new" "$cli_new"

if ! start_and_verify; then
    logread -e easytier 2>/dev/null | tail -n 80 || true
    rollback_binaries
    fail "EasyTier 新版本启动失败，已尝试回滚"
fi

printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"
REPLACE_ACTIVE=0
rm -f "$CORE_BAK" "$CLI_BAK"
CORE_BAK=""
CLI_BAK=""
HAD_CORE=0
HAD_CLI=0

log ""
log "=================================================="
log " EasyTier OpenWrt Web-managed 安装/更新完成"
log "=================================================="
log "Version:       $NEW_VERSION"
log "Config Server: $CONFIG_SERVER"
log "RPC Portal:    127.0.0.1:$RPC_PORT"
log "Machine ID:    $(cat "$MACHINE_ID_FILE")"
log "Config Dir:    $CONFIG_DIR"
log "TUN Name:      $TUN_NAME（Web 配置必须保持一致）"
log "Listener Port: $LISTENER_PORT（请在 Web Listener 中配置 TCP/UDP）"
log "Firewall:      $AUTO_FIREWALL"
log "WAN Listener:  $OPEN_WAN_LISTENER"
log ""
log "重要：Web Config Server 模式下 Listener/dev_name 属于 Web 下发的网络实例配置，"
log "本安装脚本不会通过 Core 启动参数强行覆盖它们。"
log ""
log "Web 中建议设置："
log "  dev_name = $TUN_NAME"
log "  tcp://0.0.0.0:$LISTENER_PORT"
log "  udp://0.0.0.0:$LISTENER_PORT"
log ""
log "默认防火墙允许：EasyTier -> LAN、LAN -> EasyTier。"
if [ "$OPEN_WAN_LISTENER" = "1" ]; then
    log "已放行 WAN -> $LISTENER_PORT/TCP+UDP。"
else
    log "未自动放行 WAN -> $LISTENER_PORT；需要公网主动连接时使用 --open-wan-listener。"
fi
log ""
log "常用命令："
log "  /etc/init.d/easytier status"
log "  /etc/init.d/easytier restart"
log "  logread -e easytier"
log "  easytier-cli -p 127.0.0.1:$RPC_PORT node"
