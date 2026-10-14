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
read_pairs() {
    local file="$1" line k v trimmed
    [ -f "$file" ] || die "缺少配置：$file，请先运行 sudo bash deploy.sh env"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in ''|\#*) continue ;; esac
        [[ "$trimmed" == *=* ]] || die "$file 中存在非 KEY=VALUE 行"
        k="${trimmed%%=*}"; v="${trimmed#*=}"
        k="${k%"${k##*[![:space:]]}"}"
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$file 的变量名不合法"
        if (( ${#v} >= 2 )); then
            case "$v" in \"*\") v="${v:1:${#v}-2}" ;; \'*\') v="${v:1:${#v}-2}" ;; esac
        fi
        # Only import this module's variables + shared timezone.
        case "$k" in MIHOMO_*|TZ) printf -v "$k" '%s' "$v"; export "$k" ;; esac
    done < "$file"
}
load_settings() {
    local root="$1"
    local ordinary="$root/deploy/.env" private="$root/deploy/.secrets"
    [ -f "$ordinary" ] && [ -f "$private" ] || die "请先运行 sudo bash deploy.sh env"
    chown root:root "$ordinary" "$private"
    chmod 0600 "$ordinary" "$private"
    read_pairs "$ordinary"
    read_pairs "$private"
    SECRETS_FILE="$private"
}

# Autogenerate only when the user explicitly left an optional setting empty.
# No character set or length restrictions on nonempty user-provided credentials.
secret_when_blank() {
    local key="$1" value="${!1:-}" generated
    [ -z "$value" ] || return 0
    generated="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    [ "${#generated}" -eq 64 ] || die "无法生成随机密钥"
    if grep -Eq "^$key=$" "$SECRETS_FILE"; then
        sed -i "s/^$key=$/$key=$generated/" "$SECRETS_FILE"
    elif grep -q "^$key=" "$SECRETS_FILE"; then
        die "$key 格式异常，读取为空但配置行不为空；请检查 .secrets"
    else
        printf '%s=%s\n' "$key" "$generated" >> "$SECRETS_FILE"
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
# Generate official Mihomo external-controller-cors from the NAS IPv4 interfaces.
# There is no additional user-facing WEB_ORIGIN setting; edit the native Profile
# YAML only when using an origin not covered by the interface list.
cors_yaml() {
    local port="$1" addr
    local -a origins=("http://localhost:$port" "http://127.0.0.1:$port")
    if command -v hostname >/dev/null 2>&1; then
        for addr in $(hostname -I 2>/dev/null || :); do
            [[ "$addr" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && origins+=("http://$addr:$port")
        done
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
