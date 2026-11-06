#!/usr/bin/env bash
# Standalone helpers for the MetaCubeXD All-in-One deploy. Never source .secrets.
die() { printf 'Mihomo 部署错误：%s\n' "$*" >&2; exit 1; }

must_be_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 sudo bash deploy.sh mihomo 运行"
}
docker_ready() {
    command -v docker >/dev/null 2>&1 || die "Docker 未安装"
    docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2"
    docker info >/dev/null 2>&1 || die "Docker daemon 不可用"
}

# .env / .secrets are simple KEY=VALUE records, not executable shell programs.
# Preserve the original value, including punctuation and interior whitespace.
# Return 1 for comments/empty lines; write the decoded key/value to caller locals.
# Whitespace in the VALUE is credential data, never formatting to trim.
decode_pair() {
    local decoded_line="${1%$'\r'}" decoded_key decoded_value
    decoded_line="${decoded_line#"${decoded_line%%[![:space:]]*}"}"
    case "$decoded_line" in ''|\#*) return 1 ;; esac
    [[ "$decoded_line" == *=* ]] || die "$2 中存在非 KEY=VALUE 行"
    decoded_key="${decoded_line%%=*}"; decoded_value="${decoded_line#*=}"
    decoded_key="${decoded_key%"${decoded_key##*[![:space:]]}"}"
    [[ "$decoded_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$2 的变量名不合法"
    if (( ${#decoded_value} >= 2 )); then
        case "$decoded_value" in
            \"*\"|\'*\') decoded_value="${decoded_value:1:${#decoded_value}-2}" ;;
        esac
    fi
    printf -v "$3" '%s' "$decoded_key"
    printf -v "$4" '%s' "$decoded_value"
}
read_pairs() {
    local file line k v
    local -A seen=()
    for file in "$@"; do
        [ -f "$file" ] || die "缺少配置：$file，请先运行 sudo bash deploy.sh env"
        while IFS= read -r line || [ -n "$line" ]; do
            decode_pair "$line" "$file" k v || continue
            [[ ! ${seen[$k]+defined} ]] || die "配置中变量 $k 重复定义；请保留唯一配置（值不打印）"
            seen[$k]=1
            # MYAI_IP is the existing global public IP setting; no new Mihomo variable.
            case "$k" in MIHOMO_*|TZ|MYAI_IP) printf -v "$k" '%s' "$v"; export "$k" ;; esac
        done < "$file"
    done
}
load_settings() {
    local root="$1"
    if [ -f "$root/mihomo/deploy/config.env.example" ]; then
        local config_lib="$root/deploy/lib/app-config.sh"
        [ -f "$config_lib" ] || config_lib="$root/lib/app-config.sh"
        # shellcheck source=../../lib/app-config.sh
        source "$config_lib"
        deploy_load_app_config "$root" mihomo
        return $?
    fi
    local ordinary="$root/deploy/.env" private="$root/deploy/.secrets"
    [ -f "$ordinary" ] && [ -f "$private" ] || die "请先运行 sudo bash deploy.sh env"
    chown root:root "$ordinary" "$private"
    chmod 0600 "$ordinary" "$private"
    read_pairs "$ordinary" "$private"
    SECRETS_FILE="$private"
}

# Autogenerate only when the user explicitly left an optional setting empty.
# No character set or length restrictions on nonempty user-provided credentials.
secret_when_blank() {
    local key="$1" value="${!1:-}" generated line k v stored="" index=-1 temp ending=""
    local -a records=()
    local -A seen=()
    [ -f "$SECRETS_FILE" ] || die "缺少敏感配置，请先运行 sudo bash deploy.sh env"
    # Re-read the same syntax as read_pairs before writing: stale environment
    # values must never overwrite a configured nonempty value or hide duplicates.
    while IFS= read -r line || [ -n "$line" ]; do
        if decode_pair "$line" "$SECRETS_FILE" k v; then
            [[ ! ${seen[$k]+defined} ]] || die "敏感配置中变量 $k 重复定义；未写入任何密钥（值不打印）"
            seen[$k]=1
            if [ "$k" = "$key" ]; then
                index=${#records[@]}
                stored="$v"
            fi
        fi
        records+=("$line")
    done < "$SECRETS_FILE"
    if [ -n "$stored" ]; then
        printf -v "$key" '%s' "$stored"
        export "$key"
        return 0
    fi
    [ -z "$value" ] || return 0
    generated="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    [ "${#generated}" -eq 64 ] || die "无法生成随机密钥"
    if (( index >= 0 )); then
        line="${records[index]}"
        [[ "$line" != *$'\r' ]] || ending=$'\r'
        records[index]="${line%%=*}=$generated$ending"
    else
        records+=("$key=$generated")
    fi
    # Terminate every record, including a previously unterminated final line,
    # so an omitted key cannot be concatenated onto another credential's value.
    # Stage beside the original for atomic replacement, retaining its ownership.
    temp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXXXX")" || die "无法暂存敏感配置"
    if ! cp -p -- "$SECRETS_FILE" "$temp" || ! chmod 0600 "$temp" ||
       ! printf '%s\n' "${records[@]}" > "$temp" || ! mv -f -- "$temp" "$SECRETS_FILE"; then
        rm -f -- "$temp"
        die "无法持久化 $key；请检查敏感配置文件权限"
    fi
    printf -v "$key" '%s' "$generated"
    export "$key"
    echo "已持久化空缺的 $key（值不打印）"
}
check_port() {
    local label="$1" p="$2"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || die "$label 必须是端口数字"
    (( 10#$p >= 1 && 10#$p <= 65535 )) || die "$label 超出 TCP 端口范围"
}
check_ipv4() {
    local label="$1" ip="$2" octet
    local -a a
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "$label 必须是 IPv4 地址"
    IFS=. read -r -a a <<< "$ip"
    for octet in "${a[@]}"; do (( 10#$octet <= 255 )) || die "$label 包含无效 IPv4 段"; done
}
yaml_scalar() {
    local s="$1"
    s="${s//\'/\'\'}"
    printf "'%s'" "$s"
}
# Generate native Mihomo CORS origins from the NAS interfaces and the existing
# global MYAI_IP. Origins use the Web port (7012), never the core API port (7013).
cors_yaml() {
    local port="$1" addr origin item found
    local -a origins=("http://localhost:$port" "http://127.0.0.1:$port")
    if command -v hostname >/dev/null 2>&1; then
        for addr in $(hostname -I 2>/dev/null || :); do
            [[ "$addr" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && origins+=("http://$addr:$port")
        done
    fi
    if [ -n "${MYAI_IP:-}" ]; then
        check_ipv4 MYAI_IP "$MYAI_IP"
        origin="http://$MYAI_IP:$port"
        found=0
        for item in "${origins[@]}"; do
            if [ "$item" = "$origin" ]; then found=1; break; fi
        done
        if [ "$found" -eq 0 ]; then origins+=("$origin"); fi
    fi
    printf 'external-controller-cors:\n  allow-private-network: true\n  allow-origins:\n'
    for addr in "${origins[@]}"; do printf '    - %s\n' "$(yaml_scalar "$addr")"; done
}

# Must not take over unrelated user containers or an incompatible named network.
assert_our_container() {
    local actual
    if docker container inspect mihomo >/dev/null 2>&1; then
        actual="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' mihomo)"
        [ "$actual" = mihomo ] || die "已有非 deploy/mihomo 管理的同名容器，拒绝接管"
    fi
}
