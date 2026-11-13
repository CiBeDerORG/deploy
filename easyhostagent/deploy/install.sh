#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

agent_fail() { printf 'EasyHostAgent：%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || agent_fail "必须使用 sudo 执行原生 Agent 安装"
mode="${1:-install}"
case "$mode" in install|update|force-update) ;; *) agent_fail "仅支持 install/update/force-update" ;; esac

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$MODULE/.." && pwd)"
source "$HERE/config.sh"

# 以统一 .env 为来源，不信任外部传入的同名环境变量。
unset EASYHOSTAGENT_RELEASE EASYHOSTAGENT_LOCAL_BINARY EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS
unset EASYHOSTAGENT_LOG_LEVEL EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_PLATFORM
unset EASYHOSTAGENT_CONTROLLER_URL EASYHOSTAGENT_DISCOVERY_TOKEN
agent_load_env "$SOFTWARE_ROOT/deploy/.env"
agent_load_discovery_secret "$SOFTWARE_ROOT/deploy/.secrets"
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
if [[ "$mode" != install && ! -f "$marker" ]]; then
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
# 强制更新明确忽略本地包选项，重新获取并校验所配置 Release 的最新发布资产。
if [[ -n "$EASYHOSTAGENT_LOCAL_BINARY" && "$mode" != force-update ]]; then
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
    # 在线模式先用公共 Release 来源轮换下载，校验成功才交给原生安装器。
    downloader="$SOFTWARE_ROOT/deploy/lib/release-sources.sh"
    [[ -f "$downloader" && ! -L "$downloader" ]] || agent_fail "公共 Release 下载模块不存在，请更新 deploy 仓库"
    source "$downloader"
    case "$(uname -m)" in
        x86_64|amd64) asset="easyhostagent-linux-amd64" ;;
        aarch64|arm64) asset="easyhostagent-linux-arm64" ;;
        *) agent_fail "不支持的 CPU 架构" ;;
    esac
    tmp_release="$(mktemp -d /tmp/easyhostagent-release.XXXXXXXX)"
    trap 'rm -rf -- "$tmp_release"' EXIT
    release_base="https://github.com/CiBeDerORG/EasyHostAgent/releases/download/$EASYHOSTAGENT_RELEASE"
    deploy_download_github_release_pair "$SOFTWARE_ROOT" "$SOFTWARE_ROOT/deploy/.env" "$release_base" "$asset" "$tmp_release" ||
        agent_fail "全部下载源失败或校验未通过，现有 Agent 未替换"
    chmod 0755 "$tmp_release/$asset"
    installer_args+=(--binary "$tmp_release/$asset")
fi
# 本地上传和在线下载都先通过 SHA-256 校验，再由上游原生安装器安装。
bash "$MODULE/native/scripts/install.sh" "${installer_args[@]}"

# 仅更新本模块声明的配置项，保留 Agent 的其他独立配置和身份文件。
agent_merge_native_config() {
    local file="$1" tmp line key
    local -A written=()
    local -a keys=(EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_LOG_LEVEL
                   EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS EASYHOSTAGENT_CONTROLLER_URL
                   EASYHOSTAGENT_DISCOVERY_TOKEN)
    # 未显式填写平台时，保留原生配置已有值，由 Agent 自行检测。
    if [[ -n "$EASYHOSTAGENT_PLATFORM" ]]; then
        keys+=(EASYHOSTAGENT_PLATFORM)
    fi
    [[ -f "$file" && ! -L "$file" ]] || agent_fail "原生配置文件丢失或不是普通文件"
    tmp="$(mktemp "${file}.XXXXXX")"
    chmod 0600 "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        case "$key" in
            EASYHOSTAGENT_DATA_DIR|EASYHOSTAGENT_SOFTWARE_ROOT|EASYHOSTAGENT_LOG_LEVEL|EASYHOSTAGENT_TRANSPORT|EASYHOSTAGENT_LISTEN_ADDRESS|EASYHOSTAGENT_PLATFORM|EASYHOSTAGENT_CONTROLLER_URL|EASYHOSTAGENT_DISCOVERY_TOKEN)
                if [[ "$key" == EASYHOSTAGENT_PLATFORM && -z "$EASYHOSTAGENT_PLATFORM" ]]; then
                    # 统一配置未覆盖平台，不能擦除用户原有的原生显式设置。
                    printf '%s\n' "$line" >> "$tmp"
                    continue
                fi
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
echo "原生配置：$native_config；配对身份与已安装应用记录保留（无需逐应用授权）"
if [[ "$EASYHOSTAGENT_TRANSPORT" == http ]]; then
    echo "注意：HTTP 为明文管理接口，必须在防火墙限制可信来源，禁止直接暴露公网。"
fi
if [[ "$EASYHOSTAGENT_CONTROLLER_URL" == http://* ]]; then
    echo "警告：EasyNetTopo 反向接入正在使用 HTTP 明文传输，Bootstrap Token、Agent Token 和应用配置可能被窃听；仅限可信隔离网络。"
fi
