#!/usr/bin/env bash
# 由 install.sh 加载。只解析 EasyNetTopo 使用的键，不执行配置文件中的内容。
load_settings() {
    local file="$1" kind="$2" line key value
    local -A seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || fail "$file 存在非 KEY=VALUE 配置行"
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        case "$key" in
            EASYNETTOPO_ADMIN_USERNAME|EASYNETTOPO_ADMIN_PASSWORD)
                [[ "$kind" == secrets ]] || fail "$key 只能写在 .secrets" ;;
            EASYNETTOPO_HTTP_PORT|EASYNETTOPO_BIND_IP|EASYNETTOPO_GIT_ALLOWED_HOSTS|EASYNETTOPO_GIT_ALLOW_HTTP|TZ)
                [[ "$kind" == env ]] || fail "$key 应写在 .env" ;;
            *) continue ;;
        esac
        [[ ! ${seen[$key]+defined} ]] || fail "$file 重复定义了 $key"
        seen[$key]=1
        value="${line#*=}"
        case "$value" in
            \"*|\'*)
                [[ ${#value} -ge 2 && "${value:0:1}" == "${value: -1}" ]] || fail "$key 引号未闭合"
                value="${value:1:${#value}-2}" ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$file"
}

# 只替换目标空行或补写缺失的键。密码始终走 Bash 内建命令，不出现在外部进程参数中。
persist_generated_password() (
    local tmp line found=0
    tmp="$(mktemp -- "$SECRETS_FILE.tmp.XXXXXXXX")"
    trap 'rm -f -- "$tmp"' EXIT
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*EASYNETTOPO_ADMIN_PASSWORD[[:space:]]*= ]]; then
            printf 'EASYNETTOPO_ADMIN_PASSWORD=%s\n' "$EASYNETTOPO_ADMIN_PASSWORD"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$SECRETS_FILE" > "$tmp"
    if (( ! found )); then
        printf 'EASYNETTOPO_ADMIN_PASSWORD=%s\n' "$EASYNETTOPO_ADMIN_PASSWORD" >> "$tmp"
    fi
    mv -f -- "$tmp" "$SECRETS_FILE"
)

bootstrap_admin() {
    local status
    # 数据库可能已经建表但尚无管理员，例如上一次安装在初始化前退出。
    status="$(compose exec -T easynettopo wget -qO- http://127.0.0.1:8080/api/v1/auth/status)" ||
        fail "读取管理员初始化状态失败"
    case "$status" in
        *'"initialized":true'*) return 0 ;;
        *'"initialized":false'*) ;;
        *) fail "无法识别管理员初始化状态" ;;
    esac
    [[ -f "$SECRETS_FILE" && ! -L "$SECRETS_FILE" && "$(stat -c '%u:%g:%a' "$SECRETS_FILE")" == 0:0:600 ]] ||
        fail ".secrets 必须是 root:root 所有、权限 0600 的普通文件"
    load_settings "$SECRETS_FILE" secrets
    EASYNETTOPO_ADMIN_USERNAME="${EASYNETTOPO_ADMIN_USERNAME:-admin}"
    if [[ -z "${EASYNETTOPO_ADMIN_PASSWORD:-}" ]]; then
        EASYNETTOPO_ADMIN_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
        [[ ${#EASYNETTOPO_ADMIN_PASSWORD} == 48 ]] || fail "随机密码生成失败"
        persist_generated_password
    fi
    printf '%s\n%s\n' "$EASYNETTOPO_ADMIN_USERNAME" "$EASYNETTOPO_ADMIN_PASSWORD" |
        compose exec -T easynettopo /usr/local/bin/easynettopo admin init --stdin ||
        fail "管理员初始化失败，请检查 .secrets 中的账号和密码后重试"
    unset EASYNETTOPO_ADMIN_USERNAME EASYNETTOPO_ADMIN_PASSWORD
    echo "管理员已初始化，凭据保存在 $SECRETS_FILE"
}
