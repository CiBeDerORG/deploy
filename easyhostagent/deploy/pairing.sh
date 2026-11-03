#!/usr/bin/env bash
# 在宿主机可信终端生成并打印最新的一次性配对信息；不重新安装 Agent。
set -Eeuo pipefail
set +x
umask 077

agent_fail() { printf 'EasyHostAgent 配对：%s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || agent_fail "需要 root 权限，请使用 sudo bash deploy.sh easyhostagent pairing"

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.sh"

binary=/usr/local/bin/easyhostagent
native_config=/etc/easyhostagent/agent.env

# 沿用原生安装器的隔离测试入口；正式环境始终使用已安装的 systemd 服务。
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
# 仅解析本机受控的配置键，绝不执行 .env 内容，也不使用 deploy 的默认数据目录。
unset EASYHOSTAGENT_DATA_DIR EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS EASYHOSTAGENT_LOG_LEVEL
agent_load_env "$native_config"
[[ -n "${EASYHOSTAGENT_DATA_DIR:-}" ]] ||
    agent_fail "原生配置缺少 EASYHOSTAGENT_DATA_DIR，拒绝使用默认目录生成另一份 Agent 身份"
export EASYHOSTAGENT_DATA_DIR
for key in EASYHOSTAGENT_SOFTWARE_ROOT EASYHOSTAGENT_TRANSPORT EASYHOSTAGENT_LISTEN_ADDRESS EASYHOSTAGENT_LOG_LEVEL; do
    if [[ ${!key+x} ]]; then
        export "$key"
    fi
done

printf 'EasyHostAgent 最新一次性配对信息（仅在可信终端查看，请勿分享）\n'
"$binary" -pairing-code
