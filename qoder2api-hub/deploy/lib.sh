#!/usr/bin/env bash
# Qoder2API Hub deployment helpers. Config files are parsed as data, never sourced.
PLATFORM_LIB="$SOFTWARE_ROOT/deploy/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || PLATFORM_LIB="$SOFTWARE_ROOT/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || { echo "缺少跨平台 Deploy 辅助脚本。" >&2; exit 1; }
# shellcheck source=../../lib/platform.sh
source "$PLATFORM_LIB"
fail() { printf 'Qoder2API Hub 部署错误：%s\n' "$*" >&2; exit 1; }
require_root() {
    deploy_require_root "$@" || fail "请使用 root 或 sudo 执行。"
}
check_docker() {
    command -v docker >/dev/null 2>&1 || fail "未安装 Docker。"
    docker compose version >/dev/null 2>&1 || fail "未安装 Docker Compose v2 Plugin。"
    docker info >/dev/null 2>&1 || fail "Docker daemon 不可用。"
}
QODER_CONFIG_SEEN=()
load_config_file() {
    local file="$1" kind="$2" line key value line_no=0
    [ -f "$file" ] || fail "配置文件不存在：$file"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line_no=$((line_no + 1))
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || fail "$file:$line_no 应为 KEY=VALUE"
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "$file:$line_no 变量名非法"
        case "$key" in
            QODER2API_HUB_IMAGE|QODER2API_HUB_BIND_IP|QODER2API_HUB_PORT|TZ)
                [ "$kind" = env ] || continue
                ;;
            QODER2API_HUB_API_KEY|QODER2API_HUB_HTTP_PROXY|QODER2API_HUB_HTTPS_PROXY|QODER2API_HUB_ALL_PROXY)
                [ "$kind" = secrets ] || fail "$key 属于敏感配置，请放入 deploy/.secrets"
                ;;
            *) continue ;;
        esac
        local seen_key duplicate=0
        for seen_key in "${QODER_CONFIG_SEEN[@]}"; do
            [ "$seen_key" = "$key" ] && { duplicate=1; break; }
        done
        [ "$duplicate" -eq 0 ] || fail "$key 在统一配置中重复定义；拒绝猜测应使用哪个值"
        QODER_CONFIG_SEEN+=("$key")
        value="${line#*=}"
        if [ -n "$value" ]; then
            case "${value:0:1}" in
                '"')
                    [ "${value: -1}" = '"' ] || fail "$file:$line_no 双引号未闭合"
                    value="${value:1:${#value}-2}"
                    ;;
                "'")
                    [ "${value: -1}" = "'" ] || fail "$file:$line_no 单引号未闭合"
                    value="${value:1:${#value}-2}"
                    ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
}
load_global_config() {
    if [ -f "$BASE_DIR/deploy/config.env.example" ]; then
        local config_lib="$SOFTWARE_ROOT/deploy/lib/app-config.sh"
        [ -f "$config_lib" ] || config_lib="$SOFTWARE_ROOT/lib/app-config.sh"
        # shellcheck source=../../lib/app-config.sh
        source "$config_lib"
        deploy_load_app_config "$SOFTWARE_ROOT" "$(basename "$BASE_DIR")"
        return $?
    fi
    [ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] || fail "请先执行 deploy.sh env 初始化统一配置"
    deploy_secure_config_files "$ENV_FILE" "$SECRETS_FILE" || fail "无法安全设置统一配置文件权限"
    QODER_CONFIG_SEEN=()
    load_config_file "$ENV_FILE" env
    load_config_file "$SECRETS_FILE" secrets
}
validate_port() {
    local key="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )) ||
        fail "$key 必须是 1-65535 范围内的数字端口"
}
validate_ipv4() {
    local key="$1" ip="$2" octet
    local -a parts=()
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "$key 必须是有效 IPv4 地址"
    IFS=. read -r -a parts <<< "$ip"
    for octet in "${parts[@]}"; do
        (( 10#$octet <= 255 )) || fail "$key 必须是有效 IPv4 地址"
    done
}
verify_container_owner() {
    local name="$1" expected="$2" actual
    if docker container inspect "$name" >/dev/null 2>&1; then
        actual="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
        [ "$actual" = "$expected" ] || fail "已有同名容器 $name，但不属于 Compose 项目 $expected；拒绝接管或删除"
    fi
}
