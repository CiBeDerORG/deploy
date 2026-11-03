#!/usr/bin/env bash
# 仅在宿主机可信终端修改指定应用授权，不接受远程请求自动授权。
set -Eeuo pipefail
set +x
umask 077
fail() { printf 'EasyHostAgent 授权失败：%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || fail "请以 sudo 运行授权命令"
(( $# >= 3 )) || fail "用法：deploy.sh easyhostagent grant 控制端UUID 来源UUID sub2api [portainer]"
controller="$1"
source_id="$2"
shift 2
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "$controller" =~ $uuid && "$source_id" =~ $uuid ]] || fail "UUID 格式不合法"
for app in "$@"; do
    case "$app" in sub2api|portainer) ;; *) fail "此命令仅支持 sub2api 和 portainer" ;; esac
done

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
deploy_root="$(cd -- "$here/../.." && pwd)"
global_env="$deploy_root/.env"
native_env=/etc/easyhostagent/agent.env
# Test-only staging requires the same explicit two-part opt-in as the
# existing native installer; production never redirects the system config.
if [[ -n "${EASYHOSTAGENT_STAGING_ROOT:-}" ]]; then
    [[ -n "${EASYHOSTAGENT_TEST_BINARY:-}" &&
       "${EASYHOSTAGENT_STAGING_ROOT}" == /* &&
       -d "${EASYHOSTAGENT_STAGING_ROOT}" &&
       ! -L "${EASYHOSTAGENT_STAGING_ROOT}" ]] ||
        fail "隔离测试配置无效"
    native_env="${EASYHOSTAGENT_STAGING_ROOT}/etc/easyhostagent/agent.env"
fi
[[ -f "$global_env" && ! -L "$global_env" && -f "$native_env" && ! -L "$native_env" ]] ||
    fail "请先安装 Agent 并配置统一 .env"
command -v systemctl >/dev/null || fail "没有 systemctl"
command -v flock >/dev/null || fail "没有 flock"
mkdir -p "$deploy_root/state"
exec 8>"$deploy_root/state/easyhostagent.lock"
flock -n 8 || fail "Agent 正在安装/更新或修改授权"

declare -a grants=()
declare -A seen=()
read_existing() {
    local file="$1" line value key
    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" != EASYHOSTAGENT_APP_GRANTS=* ]]; then continue; fi
        ((count+=1))
        ((count==1)) || fail "$file 中授权项重复定义"
        value="${line#*=}"
        if (( ${#value} >= 2 )) && [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        [[ "$value" =~ ^[A-Za-z0-9,/._-]*$ ]] || fail "$file 中已有授权格式无法安全读取"
        local -a parts=()
        IFS=, read -r -a parts <<< "$value"
        for key in "${parts[@]}"; do
            [[ -n "$key" ]] || continue
            if [[ ! ${seen[$key]+yes} ]]; then
                seen[$key]=1
                grants+=("$key")
            fi
        done
    done < "$file"
}
read_existing "$global_env"
read_existing "$native_env"
for app in "$@"; do
    value="$controller/$source_id/$app"
    if [[ ! ${seen[$value]+yes} ]]; then
        grants+=("$value")
        seen[$value]=1
    fi
done
joined="$(IFS=,; printf '%s' "${grants[*]}")"
[[ -n "$joined" ]] || fail "没有可保存的授权"
for app in "$@"; do
    if [[ ${seen["$controller/$source_id"]+yes} ]]; then
        printf '注意：此控制端已有整个 Git 来源的宽授权，本次操作不会自动收窄已有权限。\n' >&2
        break
    fi
done

declare -a temps=() backups=()
cleanup() {
    for file in "${temps[@]}" "${backups[@]}"; do
        [[ -z "$file" ]] || rm -f -- "$file"
    done
}
trap cleanup EXIT
for file in "$global_env" "$native_env"; do
    temp="$(mktemp "${file}.grant.XXXXXXXX")" || fail "无法创建配置临时文件"
    backup="$(mktemp "${file}.backup.XXXXXXXX")" || fail "无法备份配置"
    temps+=("$temp")
    backups+=("$backup")
    cp -p -- "$file" "$backup" || fail "备份失败"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == EASYHOSTAGENT_APP_GRANTS=* ]]; then
            continue
        fi
        printf '%s\n' "$line"
    done < "$file" > "$temp"
    printf 'EASYHOSTAGENT_APP_GRANTS=%s\n' "$joined" >> "$temp"
    chown root:root "$temp"
    chmod 0600 "$temp"
done
mv -f -- "${temps[0]}" "$global_env" || fail "更新统一配置失败"
temps[0]=''
if ! mv -f -- "${temps[1]}" "$native_env"; then
    cp -p -- "${backups[0]}" "$global_env"
    fail "更新 Agent 原生配置失败，已恢复原设置"
fi
temps[1]=''
if ! systemctl restart easyhostagent.service || ! systemctl is-active --quiet easyhostagent.service; then
    cp -p -- "${backups[0]}" "$global_env"
    cp -p -- "${backups[1]}" "$native_env"
    systemctl restart easyhostagent.service || true
    fail "Agent 无法加载新的授权，请先确认已更新为支持应用级授权的版本；配置已恢复"
fi
printf 'EasyHostAgent 授权已生效：'
printf '%s ' "$@"
printf '\n请回到 EasyNetTopo 点击「刷新状态」。\n'
