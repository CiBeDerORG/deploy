#!/usr/bin/env bash
# 只读取 EasyHostAgent 的统一配置，不执行 .env 中的命令。
agent_load_env() {
    local file="$1" line key value
    local -A seen=()
    [[ -f "$file" && ! -L "$file" ]] || agent_fail "统一 .env 不可用"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || agent_fail "配置行缺少等号"
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        case "$key" in
            EASYHOSTAGENT_LOCAL_BINARY|EASYHOSTAGENT_TRANSPORT|EASYHOSTAGENT_LISTEN_ADDRESS|EASYHOSTAGENT_LOG_LEVEL|EASYHOSTAGENT_DATA_DIR|EASYHOSTAGENT_SOFTWARE_ROOT|EASYHOSTAGENT_PLATFORM) ;;
            *) continue ;;
        esac
        [[ ! ${seen[$key]+ok} ]] || agent_fail "重复配置：$key"
        seen[$key]=1
        value="${line#*=}"
        case "$value" in
            \"*|\'*) [[ ${#value} -gt 1 && "${value:0:1}" == "${value: -1}" ]] || agent_fail "$key 引号错误"
                 value="${value:1:${#value}-2}" ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$file"
}

agent_valid_path() {
    local name="$1" value="$2"
    [[ "$value" == /* && "$value" != "/" && "$value" =~ ^/[a-zA-Z0-9/_:.-]+$ ]] ||
        agent_fail "$name 必须是安全的绝对路径"
    [[ "/$value/" != *"/../"* && "/$value/" != *"/./"* ]] || agent_fail "$name 不允许路径穿越"
}

agent_validate_env() {
    source "$SOFTWARE_ROOT/deploy/lib/versions.sh"
    deploy_load_versions "$SOFTWARE_ROOT" || agent_fail "仓库版本文件不可用"
    EASYHOSTAGENT_RELEASE="$EASYHOSTAGENT_RELEASE"
    EASYHOSTAGENT_LOCAL_BINARY="${EASYHOSTAGENT_LOCAL_BINARY:-}"
    EASYHOSTAGENT_TRANSPORT="${EASYHOSTAGENT_TRANSPORT:-https}"
    EASYHOSTAGENT_LISTEN_ADDRESS="${EASYHOSTAGENT_LISTEN_ADDRESS:-0.0.0.0:7018}"
    EASYHOSTAGENT_LOG_LEVEL="${EASYHOSTAGENT_LOG_LEVEL:-info}"
    EASYHOSTAGENT_DATA_DIR="${EASYHOSTAGENT_DATA_DIR:-/var/lib/easyhostagent}"
    EASYHOSTAGENT_SOFTWARE_ROOT="${EASYHOSTAGENT_SOFTWARE_ROOT:-$SOFTWARE_ROOT}"
    EASYHOSTAGENT_PLATFORM="${EASYHOSTAGENT_PLATFORM:-}"
    [[ "$EASYHOSTAGENT_RELEASE" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] ||
        agent_fail "Release 版本格式不合法"
    if [[ -n "$EASYHOSTAGENT_LOCAL_BINARY" ]]; then
        agent_valid_path EASYHOSTAGENT_LOCAL_BINARY "$EASYHOSTAGENT_LOCAL_BINARY"
    fi
    case "$EASYHOSTAGENT_TRANSPORT" in http|https) ;; *) agent_fail "传输模式应为 http 或 https" ;; esac
    case "$EASYHOSTAGENT_PLATFORM" in ''|fnos|linux) ;; *) agent_fail "Agent 平台只能为 fnos、linux 或留空自动识别" ;; esac
    case "$EASYHOSTAGENT_LOG_LEVEL" in debug|info|warn|error) ;; *) agent_fail "日志等级无效" ;; esac
    [[ "$EASYHOSTAGENT_LISTEN_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] ||
        agent_fail "监听地址应为 IPv4:端口"
    local host="${EASYHOSTAGENT_LISTEN_ADDRESS%:*}" port="${EASYHOSTAGENT_LISTEN_ADDRESS##*:}" octet
    local -a octets=()
    IFS='.' read -r -a octets <<< "$host"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || agent_fail "IPv4 地址段非法"
    done
    (( 10#$port > 0 && 10#$port <= 65535 )) || agent_fail "端口应为 1–65535"
    agent_valid_path EASYHOSTAGENT_SOFTWARE_ROOT "$EASYHOSTAGENT_SOFTWARE_ROOT"
    agent_valid_path EASYHOSTAGENT_DATA_DIR "$EASYHOSTAGENT_DATA_DIR"
    [[ "$EASYHOSTAGENT_DATA_DIR" != "$EASYHOSTAGENT_SOFTWARE_ROOT" ]] ||
        agent_fail "数据目录不能等于软件根目录"
}
