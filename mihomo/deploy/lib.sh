#!/usr/bin/env bash
# Shared by this service's install and update entry points.
fail() { echo "部署错误：$*" >&2; exit 1; }
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then exec sudo -- bash "$0" "$@"; fi
        fail "请使用 root 或 sudo 执行。"
    fi
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
    [ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ] || fail "请先执行 sudo bash deploy.sh env"
    chown root:root "$ENV_FILE" "$SECRETS_FILE"
    chmod 0600 "$ENV_FILE" "$SECRETS_FILE"
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
    if grep -q "^$key=$" "$SECRETS_FILE"; then
        sed -i "s/^$key=$/$key=$generated/" "$SECRETS_FILE"
    elif ! grep -q "^$key=" "$SECRETS_FILE"; then
        printf '%s=%s\n' "$key" "$generated" >> "$SECRETS_FILE"
    else
        fail "$key 已配置但读取为空，请检查 .secrets 格式"
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

# Escape YAML single-quoted scalars without modifying the decoded credential.
# Double only apostrophes; punctuation, spaces, quotes and backslashes stay intact.
yaml_single_quote_scalar() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

# Exact trusted Web origins; additionally include host IPv4 interfaces (EasyTier).
write_web_cors() {
    local port="$1" custom="$2" address origin
    local -a origins=("http://localhost:$port" "http://127.0.0.1:$port")
    if command -v hostname >/dev/null 2>&1; then
        for address in $(hostname -I 2>/dev/null || true); do
            if [[ "$address" =~ ^[0-9.]+$ ]]; then origins+=("http://$address:$port"); fi
        done
    fi
    if [ -n "$custom" ]; then
        [[ "$custom" =~ ^https?://[^/[:space:]]+$ ]] ||
            fail "MIHOMO_WEB_ORIGIN 应填写准确的浏览器来源（如 http://10.10.10.2:7012），不带路径"
        origins+=("$custom")
    fi
    printf 'external-controller-cors:\n  allow-private-network: true\n  allow-origins:\n'
    for origin in "${origins[@]}"; do
        printf '    - %s\n' "$(yaml_single_quote_scalar "$origin")"
    done
}

# Extract the original top-level authentication YAML block without parsing/re-encoding
# user passwords. A generated global merge overlay preserves auth across new profiles.
extract_legacy_authentication() {
    awk '
        /^authentication[[:space:]]*:/ { found=1; print; next }
        found && /^[A-Za-z0-9_-]+[[:space:]]*:/ { exit }
        found { print }
    ' "$1"
}
