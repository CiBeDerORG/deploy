#!/usr/bin/env bash
# Repository-managed version registry. Read-only data parser: NEVER source versions.env.
# Contract: all image and release versions come from <SOFTWARE_ROOT>/deploy/versions.env,
# which the deploy entrypoint synchronizes from the tracked repository file.
deploy_load_versions() {
    [ "$#" -eq 1 ] || { printf '版本配置错误：需要软件根目录\n' >&2; return 1; }
    local file="$1/deploy/lib/versions.env" line key value seen='|' name
    local required=' EASYHOSTAGENT_RELEASE GITHUB_RUNNER_VERSION EASYNETTOPO_IMAGE EASYTIER_IMAGE EASYTIER_EXECUTOR_IMAGE FRPS_IMAGE PORTAINER_IMAGE FLATNAS_IMAGE WEBTOP_IMAGE OPENHANDS_IMAGE QODER2API_HUB_IMAGE MIHOMO_IMAGE SUB2API_IMAGE SUB2API_POSTGRES_IMAGE SUB2API_REDIS_IMAGE OPENCODE_BASE_IMAGE OPENCODE_LOCAL_IMAGE OPENCODE_CLI_VERSION MIHOMO_METACUBEXD_VERSION MIHOMO_KERNEL_VERSION MIHOMO_NODE_VERSION '
    [ -f "$file" ] && [ ! -L "$file" ] || {
        printf '版本配置错误：仓库版本文件不存在：%s。请先用 deploy.sh/ps1 同步。\n' "$file" >&2
        return 1
    }
    # Old values from .env or inherited process variables MUST NOT become an override.
    for name in $required; do
        unset "$name"
    done
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *)
            printf '版本配置错误：无效 KEY=VALUE 行\n' >&2; return 1 ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$required" in *" $key "*) ;; *)
            printf '版本配置错误：未知字段 %s\n' "$key" >&2; return 1 ;;
        esac
        case "$seen" in *"|$key|"*)
            printf '版本配置错误：重复字段 %s\n' "$key" >&2; return 1 ;;
        esac
        # No quoting, shell syntax, whitespace or inline comments permitted.
        if [ -z "$value" ] || [[ ! "$value" =~ ^[a-zA-Z0-9._:/@+-]+$ ]]; then
            printf '版本配置错误：%s 的值不合法\n' "$key" >&2; return 1
        fi
        seen="$seen$key|"
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
    for name in $required; do
        if [ -z "${!name:-}" ]; then
            printf '版本配置错误：缺少 %s\n' "$name" >&2; return 1
        fi
    done
}
