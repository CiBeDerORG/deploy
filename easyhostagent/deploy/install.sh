#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

agent_fail() { printf 'EasyHostAgent：%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || agent_fail "必须使用 sudo 执行原生 Agent 安装"
mode="${1:-install}"
case "$mode" in install|update) ;; *) agent_fail "仅支持 install/update" ;; esac

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$MODULE/.." && pwd)"
source "$HERE/config.sh"

# 以统一 .env 为来源，不信任外部传入的同名环境变量。
unset EASYHOSTAGENT_RELEASE EASYHOSTAGENT_LOCAL_BINARY EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS
unset EASYHOSTAGENT_LOG_LEVEL EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_APP_GRANTS
agent_load_env "$SOFTWARE_ROOT/deploy/.env"
agent_validate_env
command -v flock >/dev/null || agent_fail "缺少 flock"
mkdir -p "$SOFTWARE_ROOT/deploy/state"
exec 8>"$SOFTWARE_ROOT/deploy/state/easyhostagent.lock"
flock -n 8 || agent_fail "已有 EasyHostAgent 安装或更新正在运行"

staging="${EASYHOSTAGENT_STAGING_ROOT:-}"
test_binary="${EASYHOSTAGENT_TEST_BINARY:-}"
if [[ -n "$staging" || -n "$test_binary" ]]; then
    [[ -n "$staging" && -n "$test_binary" ]] ||
        agent_fail "隔离测试须同时提供 staging 目录和本地测试二进制"
    [[ "$staging" == /* && -d "$staging" && ! -L "$staging" ]] ||
        agent_fail "隔离测试目录不可用"
fi
system_prefix="$staging"
native_config="$system_prefix/etc/easyhostagent/agent.env"
marker="$system_prefix/etc/easyhostagent/managed-by-installer"
if [[ -z "$staging" ]] && command -v docker >/dev/null 2>&1 &&
   docker container inspect easyhostagent >/dev/null 2>&1; then
    agent_fail "存在 EasyHostAgent Docker 容器；请先单独卸载旧容器，数据目录会保留"
fi
if [[ "$mode" == update && ! -f "$marker" ]]; then
    agent_fail "未发现由官方安装器管理的 Agent；请先执行 install"
fi
# 已经安装的 Agent 身份与受管应用依赖原数据目录，不允许普通更新意外迁移。
if [[ -f "$marker" && -f "$native_config" ]]; then
    for item in EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT; do
        previous="$(sed -n "s/^$item=//p" "$native_config" | tail -n 1)"
        if [[ -n "$previous" && "$previous" != "${!item}" ]]; then
            agent_fail "已有 $item=$previous 与统一 .env 不一致；请先按现有路径配置，迁移需另行处理"
        fi
    done
fi

installer_args=(--software-root "$EASYHOSTAGENT_SOFTWARE_ROOT" --data-dir "$EASYHOSTAGENT_DATA_DIR"
                --log-level "$EASYHOSTAGENT_LOG_LEVEL" --no-start)
if [[ -n "$staging" ]]; then
    installer_args+=(--staging-root "$staging")
fi
if [[ -n "$EASYHOSTAGENT_LOCAL_BINARY" ]]; then
    binary="$EASYHOSTAGENT_LOCAL_BINARY"
    checksum="$binary.sha256"
    [[ -f "$binary" && ! -L "$binary" && -r "$binary" ]] || agent_fail "本地安装包不存在或不可读：$binary"
    [[ -f "$checksum" && ! -L "$checksum" && -r "$checksum" ]] || agent_fail "请一并上传校验文件：$checksum"
    command -v sha256sum >/dev/null || agent_fail "缺少 sha256sum"
    [[ "$(wc -l < "$checksum")" -eq 1 ]] || agent_fail "本地校验文件必须只有一行"
    read -r expected filename < "$checksum" || agent_fail "本地校验文件无法读取"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$filename" == "$(basename -- "$binary")" ]] ||
        agent_fail "校验文件格式或二进制文件名不匹配"
    actual="$(sha256sum -- "$binary" | cut -d' ' -f1)"
    [[ "${actual,,}" == "${expected,,}" ]] || agent_fail "本地安装包 SHA-256 校验失败"
    tmp_binary="$(mktemp /tmp/easyhostagent-binary.XXXXXXXX)"
    trap 'rm -f -- "$tmp_binary"' EXIT
    install -m 0755 -- "$binary" "$tmp_binary"
    installer_args+=(--binary "$tmp_binary")
elif [[ -n "$staging" ]]; then
    # 隔离测试默认用指定的替身二进制，绝不访问生产 systemd。
    installer_args+=(--binary "$test_binary")
else
    installer_args+=(--release "$EASYHOSTAGENT_RELEASE")
fi
# 在线安装由上游安装器下载二进制并校验；离线安装已预校验上传文件。
bash "$MODULE/native/scripts/install.sh" "${installer_args[@]}"

# 仅更新本模块声明的配置项，保留 Agent 的其他独立配置和身份文件。
agent_merge_native_config() {
    local file="$1" tmp line key
    local -A written=()
    local -a keys=(EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_LOG_LEVEL
                   EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS EASYHOSTAGENT_APP_GRANTS)
    [[ -f "$file" && ! -L "$file" ]] || agent_fail "原生配置文件丢失或不是普通文件"
    tmp="$(mktemp "${file}.XXXXXX")"
    chmod 0600 "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        case "$key" in
            EASYHOSTAGENT_DATA_DIR|EASYHOSTAGENT_SOFTWARE_ROOT|EASYHOSTAGENT_LOG_LEVEL|EASYHOSTAGENT_TRANSPORT|EASYHOSTAGENT_LISTEN_ADDRESS|EASYHOSTAGENT_APP_GRANTS)
                if [[ ${written[$key]+yes} ]]; then
                    rm -f -- "$tmp"
                    agent_fail "原生配置存在重复键：$key"
                fi
                written[$key]=1
                printf '%s=%s\n' "$key" "${!key}" >> "$tmp" ;;
            *) printf '%s\n' "$line" >> "$tmp" ;;
        esac
    done < "$file"
    for key in "${keys[@]}"; do
        if [[ ! ${written[$key]+yes} ]]; then
            printf '%s=%s\n' "$key" "${!key}" >> "$tmp"
        fi
    done
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$file"
}
agent_merge_native_config "$native_config"

if [[ -z "$staging" ]]; then
    systemctl enable easyhostagent.service
    systemctl restart easyhostagent.service ||
        agent_fail "Agent 服务启动失败；运行 journalctl -u easyhostagent -n 100 查看原因"
    systemctl is-active --quiet easyhostagent.service ||
        agent_fail "Agent 未进入 active 状态"
fi
echo "EasyHostAgent 已部署，传输：$EASYHOSTAGENT_TRANSPORT，监听：$EASYHOSTAGENT_LISTEN_ADDRESS"
echo "原生配置：$native_config；身份、授权和已安装应用保留"
if [[ "$EASYHOSTAGENT_TRANSPORT" == http ]]; then
    echo "注意：HTTP 为明文管理接口，必须在防火墙限制可信来源，禁止直接暴露公网。"
fi
