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
            EASYHOSTAGENT_RELEASE|EASYHOSTAGENT_TRANSPORT|EASYHOSTAGENT_LISTEN_ADDRESS|EASYHOSTAGENT_LOG_LEVEL|EASYHOSTAGENT_DATA_DIR|EASYHOSTAGENT_SOFTWARE_ROOT|EASYHOSTAGENT_APP_GRANTS) ;;
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
