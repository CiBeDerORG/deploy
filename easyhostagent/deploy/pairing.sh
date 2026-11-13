#!/usr/bin/env bash
# 使用 EasyNetTopo 生成的短期 Token 发起内网 Agent 配对；不安装、不更新 Agent。
set -Eeuo pipefail
set +x
umask 077

agent_fail() { printf 'EasyHostAgent 配对：%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || agent_fail "需要 root 权限，请使用 sudo bash deploy.sh easyhostagent pair"

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.sh"
MODULE="$(cd -- "$here/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$MODULE/.." && pwd)"

binary=/usr/local/bin/easyhostagent
native_config=/etc/easyhostagent/agent.env

# 沿用原生安装器的隔离测试入口；正式环境要求服务正在运行。
if [[ -n "${EASYHOSTAGENT_STAGING_ROOT:-}" || -n "${EASYHOSTAGENT_TEST_BINARY:-}" ]]; then
    staging="${EASYHOSTAGENT_STAGING_ROOT:-}"
    [[ -n "$staging" && -n "${EASYHOSTAGENT_TEST_BINARY:-}" && "$staging" == /* && -d "$staging" && ! -L "$staging" ]] ||
        agent_fail "隔离测试需要有效的 staging 目录和测试二进制"
    binary="$staging/usr/local/bin/easyhostagent"
    native_config="$staging/etc/easyhostagent/agent.env"
else
    command -v systemctl >/dev/null 2>&1 || agent_fail "本机没有 systemctl，无法检查 Agent 运行状态"
    systemctl is-active --quiet easyhostagent.service ||
        agent_fail "Agent 服务尚未正常运行，请先查看 systemctl status easyhostagent 和 journalctl -u easyhostagent"
fi

[[ -f "$native_config" && ! -L "$native_config" ]] ||
    agent_fail "未找到 Agent 原生配置：$native_config，请先安装"
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] ||
    agent_fail "未找到已安装的可执行程序：$binary，请先安装"

# native CLI 不会自动读取 systemd EnvironmentFile。
# 只读取受控配置键；Token 由本次终端交互输入，不读取 .env/.secrets。
unset EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_TRANSPORT
unset EASYHOSTAGENT_LISTEN_ADDRESS EASYHOSTAGENT_LOG_LEVEL EASYHOSTAGENT_CONTROLLER_URL
agent_load_env "$native_config"
[[ -n "${EASYHOSTAGENT_DATA_DIR:-}" ]] ||
    agent_fail "原生配置缺少 EASYHOSTAGENT_DATA_DIR，拒绝使用默认目录生成另一份 Agent 身份"
[[ -n "${EASYHOSTAGENT_CONTROLLER_URL:-}" ]] ||
    agent_fail "原生配置缺少 EASYHOSTAGENT_CONTROLLER_URL；请先在统一 .env 配置控制端地址并更新 Agent"
export EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_CONTROLLER_URL
for key in EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS EASYHOSTAGENT_LOG_LEVEL; do
    if [[ ${!key+x} ]]; then
        export "$key"
    fi
done

# 清理旧版环境变量 Token；新的 Bootstrap Token 绝不写入配置文件。
agent_remove_legacy_discovery_token "$SOFTWARE_ROOT/deploy/.env"
agent_remove_legacy_discovery_token "$SOFTWARE_ROOT/deploy/.secrets"
agent_remove_legacy_discovery_token "$native_config"

status="$("$binary" -pair-status)"
replace_args=()
if [[ "$status" == "paired=true" ]]; then
    printf '当前主机已经配对，是否清除旧配对信息并重新配对？[y/N] ' >&2
    IFS= read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) replace_args=(-pair-replace) ;;
        *) printf '已取消；原配对信息保持不变。\n' >&2; exit 0 ;;
    esac
elif [[ "$status" != "paired=false" ]]; then
    agent_fail "无法识别 Agent 配对状态：$status"
fi

printf '请输入 EasyNetTopo 生成的 64 位 Token（有效期 5 分钟）：' >&2
IFS= read -r -s token || agent_fail "未读取到 Token"
printf '\n' >&2
[[ -n "$token" ]] || agent_fail "Token 不能为空"
printf '%s\n' "$token" | "$binary" -pair "${replace_args[@]}"
unset token
