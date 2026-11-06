#!/usr/bin/env bash
# Shared by this service's install and update entry points.
PLATFORM_LIB="$SOFTWARE_ROOT/deploy/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || PLATFORM_LIB="$SOFTWARE_ROOT/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || { echo "缺少跨平台 Deploy 辅助脚本。" >&2; exit 1; }
# shellcheck source=../../lib/platform.sh
source "$PLATFORM_LIB"
fail() { echo "部署错误：$*" >&2; exit 1; }
require_root() {
    deploy_require_root "$@" || fail "请使用 root 或 sudo 执行。"
}
check_docker() {
    command -v docker >/dev/null 2>&1 || fail "请先安装 Docker。"
    docker compose version >/dev/null 2>&1 || fail "请先安装 Docker Compose v2 Plugin。"
    docker info >/dev/null 2>&1 || fail "Docker daemon 不可用。"
}
load_dotenv_file() {
    local file="$1" line key value line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || fail "$file:$line_no 应为 KEY=VALUE"
        key="${line%%=*}"; value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "$file:$line_no 变量名非法"
        if [ -n "$value" ]; then
            case "${value:0:1}" in
                '"') [ "${#value}" -ge 2 ] && [ "${value: -1}" = '"' ] || fail "$file:$line_no 双引号未闭合"
                     value="${value:1:${#value}-2}" ;;
                "'") [ "${#value}" -ge 2 ] && [ "${value: -1}" = "'" ] || fail "$file:$line_no 单引号未闭合"
                     value="${value:1:${#value}-2}" ;;
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
    [ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] || fail "请先执行 sudo bash deploy.sh env"
    deploy_secure_config_files "$ENV_FILE" "$SECRETS_FILE" || fail "无法安全设置统一配置文件权限"
    load_dotenv_file "$ENV_FILE"
    load_dotenv_file "$SECRETS_FILE"
}
validate_port() {
    local v="$2"
    [[ "$v" =~ ^[0-9]+$ ]] || fail "$1 必须为数字端口"
    (( 10#$v >= 1 && 10#$v <= 65535 )) || fail "$1 必须在 1-65535 范围内"
}
validate_ipv4() {
    local ip="$2" part
    local -a parts
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "$1 必须为 IPv4"
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do (( 10#$part <= 255 )) || fail "$1 非法"; done
}
# Only fills a missing or empty example-template entry; never rotates a live secret.
ensure_hex_secret() {
    local key="$1" old generated
    old="${!key:-}"
    [ -z "$old" ] || return 0
    generated="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    [ "${#generated}" -eq 64 ] || fail "随机密钥生成失败"
    # A parsed blank can be written as KEY=, KEY="", KEY=\'\', or KEY =.
    # Do not overwrite ambiguous duplicate definitions (possibly nonempty).
    local definitions
    definitions="$(grep -Ec "^[[:space:]]*${key}[[:space:]]*=" "$SECRETS_FILE" || true)"
    if [ "$definitions" -gt 1 ]; then
        fail "$key 在 .secrets 中重复定义，请保留一行（原文件未修改）"
    elif [ "$definitions" -eq 1 ]; then
        deploy_sed_in_place -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|$key=$generated|" "$SECRETS_FILE"
    else
        printf '%s=%s\n' "$key" "$generated" >> "$SECRETS_FILE"
    fi
    printf -v "$key" '%s' "$generated"
    export "$key"
    echo "已在 .secrets 中生成并持久化 $key（不显示密钥）。"
}
verify_container_owner() {
    local name="$1" expected="$2" actual
    if docker container inspect "$name" >/dev/null 2>&1; then
        actual="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
        [ "$actual" = "$expected" ] || fail "容器 $name 已存在且不属于 $expected，请手动处理；不会接管或删除。"
    fi
}

# Official Sub2API setup checks Go len(password): 8-72 UTF-8 bytes.
# Source: https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/setup/handler.go
# Do not impose stricter deploy-only password policies.
validate_upstream_admin_password() {
    local password="$1" bytes
    bytes="$(printf '%s' "$password" | LC_ALL=C wc -c)"
    if (( bytes < 8 || bytes > 72 )); then
        fail "SUB2API_ADMIN_PASSWORD 必须符合 Sub2API 官方首次初始化要求：8-72 字节"
    fi
}
