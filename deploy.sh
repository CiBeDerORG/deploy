#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REQUESTED_SOFTWARE_ROOT="${SOFTWARE_ROOT:-}"
DEFAULT_SOFTWARE_ROOT="/software"
FNOS_SOFTWARE_ROOT="/vol3/1000/software"

SOFTWARE_ROOT=""
GLOBAL_ENV_DIR=""
GLOBAL_ENV=""
GLOBAL_SECRETS=""
LEGACY_GLOBAL_ENV=""
GLOBAL_ENV_EXAMPLE="$ROOT_DIR/.env.example"
GLOBAL_SECRETS_EXAMPLE="$ROOT_DIR/.secrets.example"
GLOBAL_ENV_CREATED=0
GLOBAL_SECRETS_CREATED=0
GLOBAL_ENV_UPDATED=0

DEPRECATED_ENV_KEYS=(
    PORTAINER_HTTP_CONTAINER_PORT
    OPENCODE_VERSION
    FRPS_IMAGE
    EASYTIER_IMAGE
    PORTAINER_IMAGE
    FRPS_VHOST_HTTP_PORT
    FRPS_VHOST_HTTPS_PORT
    FRPS_HTTP_PUBLIC_PORT
    FRPS_HTTPS_PUBLIC_PORT
    EASYTIER_WEB_USERNAME
    EASYTIER_MODE
    EASYTIER_PEERS
    EASYTIER_NETWORK_NAME
    EASYTIER_NETWORK_SECRET
    GITHUB_RUNNER_VERSION
    GITHUB_RUNNER_WORKDIR
)

SENSITIVE_ENV_KEYS=(
    OPENCODE_SERVER_PASSWORD
    FRPS_DASHBOARD_USER
    FRPS_DASHBOARD_PASSWORD
    PORTAINER_ADMIN_PASSWORD
    GITHUB_RUNNER_TOKEN
)

set_software_root() {
    SOFTWARE_ROOT="$1"
    GLOBAL_ENV_DIR="$SOFTWARE_ROOT/deploy"
    GLOBAL_ENV="$GLOBAL_ENV_DIR/.env"
    GLOBAL_SECRETS="$GLOBAL_ENV_DIR/.secrets"
    LEGACY_GLOBAL_ENV="$SOFTWARE_ROOT/.env"
}

read_env_software_root() {
    local file="$1"
    local line value

    line="$(grep -E '^SOFTWARE_ROOT=' "$file" 2>/dev/null | tail -n 1 || true)"
    [ -n "$line" ] || return 0

    value="${line#*=}"
    value="$(printf '%s' "$value" | tr -d '\r')"

    case "$value" in
        \"*\") value="${value:1:${#value}-2}" ;;
        \'*\') value="${value:1:${#value}-2}" ;;
    esac

    printf '%s\n' "$value"
}

initialize_paths() {
    local configured_root=""

    if [ -n "$REQUESTED_SOFTWARE_ROOT" ]; then
        set_software_root "$REQUESTED_SOFTWARE_ROOT"
    elif [ -f "$FNOS_SOFTWARE_ROOT/deploy/.env" ]; then
        set_software_root "$FNOS_SOFTWARE_ROOT"
    elif [ -f "$DEFAULT_SOFTWARE_ROOT/deploy/.env" ]; then
        set_software_root "$DEFAULT_SOFTWARE_ROOT"
    elif [ -d "/vol3/1000" ]; then
        set_software_root "$FNOS_SOFTWARE_ROOT"
    else
        set_software_root "$DEFAULT_SOFTWARE_ROOT"
    fi

    if [ -f "$GLOBAL_ENV" ]; then
        configured_root="$(read_env_software_root "$GLOBAL_ENV")"
        if [ -n "$configured_root" ] && [ "$configured_root" != "$SOFTWARE_ROOT" ]; then
            echo "配置错误：$GLOBAL_ENV 中 SOFTWARE_ROOT=$configured_root，但 .env 当前位于 $SOFTWARE_ROOT/deploy/.env。" >&2
            echo "请先迁移整个软件根目录，确保 .env 位于 <SOFTWARE_ROOT>/deploy/.env。" >&2
            exit 1
        fi
    fi
}

usage() {
    cat <<'EOF_USAGE'
用法：
  bash deploy.sh                       交互选择业务
  bash deploy.sh list                  列出可安装业务
  bash deploy.sh <业务类型>            同步到 <SOFTWARE_ROOT>/<业务类型> 并执行安装
  bash deploy.sh <业务类型> install    同上
  bash deploy.sh <业务类型> update     同步最新文件后执行 update.sh
  bash deploy.sh <业务类型> sync       仅同步文件，不启动/更新容器
  bash deploy.sh env                    初始化/检查 <SOFTWARE_ROOT>/deploy/.env 和 .secrets

示例：
  bash deploy.sh opencode
  bash deploy.sh frps update
  bash deploy.sh easytier sync

说明：
  deploy 仓库可以 clone/pull 到任意目录。
  实际安装根目录由统一 .env 中的 SOFTWARE_ROOT 指定。
  Ubuntu 默认 /software；fnOS 首次部署默认 /vol3/1000/software。
  所有业务统一读取 <SOFTWARE_ROOT>/deploy/.env 和 .secrets；普通配置与敏感配置分离。
  同步时会保留目标目录中的运行数据和 deploy/.secrets。
EOF_USAGE
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -- "$@"
    else
        echo "需要 root 权限写入 $SOFTWARE_ROOT，请使用 sudo 或安装 sudo。" >&2
        exit 1
    fi
}

migrate_global_env_path() {
    run_root mkdir -p "$GLOBAL_ENV_DIR"

    if [ ! -f "$GLOBAL_ENV" ] && [ -f "$LEGACY_GLOBAL_ENV" ]; then
        echo "发现旧全局配置：$LEGACY_GLOBAL_ENV"
        echo "迁移到新位置：$GLOBAL_ENV"
        run_root mv "$LEGACY_GLOBAL_ENV" "$GLOBAL_ENV"
        run_root chown root:root "$GLOBAL_ENV"
        run_root chmod 0600 "$GLOBAL_ENV"
        GLOBAL_ENV_UPDATED=1
        return 0
    fi

    if [ -f "$GLOBAL_ENV" ] && [ -f "$LEGACY_GLOBAL_ENV" ]; then
        echo "提示：检测到旧全局配置 $LEGACY_GLOBAL_ENV，但当前仅使用 $GLOBAL_ENV。" >&2
    fi
}

migrate_legacy_envs() {
    local legacy found=0

    for legacy in "$SOFTWARE_ROOT"/*/deploy/.env; do
        [ -f "$legacy" ] || continue
        found=1
        echo "发现旧配置，迁移到统一文件：$legacy"
        run_root sh -c '
            printf "\n# migrated from %s\n" "$1" >> "$2"
            cat "$1" >> "$2"
            printf "\n" >> "$2"
        ' sh "$legacy" "$GLOBAL_ENV"
    done

    if [ "$found" -eq 1 ]; then
        echo "旧业务 .env 已迁移；旧文件暂时保留作回滚备份，但后续脚本不再读取它们。"
    fi
}

remove_deprecated_env_keys() {
    local key
    for key in "${DEPRECATED_ENV_KEYS[@]}"; do
        if run_root grep -q "^$key=" "$GLOBAL_ENV"; then
            run_root sed -i "/^$key=/d" "$GLOBAL_ENV"
            GLOBAL_ENV_UPDATED=1
        fi
        if [ -f "$GLOBAL_SECRETS" ] && run_root grep -q "^$key=" "$GLOBAL_SECRETS"; then
            run_root sed -i "/^$key=/d" "$GLOBAL_SECRETS"
            GLOBAL_ENV_UPDATED=1
        fi
    done
}

sync_template_keys() {
    local template="$1" target="$2" label="$3" line key
    [ -f "$template" ] || return 0
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if ! run_root grep -q "^$key=" "$target"; then
            [ "$key" != "SOFTWARE_ROOT" ] || line="SOFTWARE_ROOT=$SOFTWARE_ROOT"
            run_root sh -c 'printf "\n%s\n" "$1" >> "$2"' sh "$line" "$target"
            echo "已补充 $label 配置项：$key"
            GLOBAL_ENV_UPDATED=1
        fi
    done < "$template"
}

set_config_line() {
    local file="$1" key="$2" line="$3"
    run_root sh -c 'sed -i "/^$2=/d" "$1"; printf "%s\n" "$3" >> "$1"' sh "$file" "$key" "$line"
}

migrate_easytier_default_ports() {
    local key old_value new_value line value
    while IFS='|' read -r key old_value new_value; do
        line="$(run_root grep -E "^$key=" "$GLOBAL_ENV" 2>/dev/null | tail -n 1 || true)"
        [ -n "$line" ] || continue
        value="${line#*=}"
        if [ "$value" = "$old_value" ]; then
            set_config_line "$GLOBAL_ENV" "$key" "$key=$new_value"
            echo "已迁移 EasyTier 默认端口：$key $old_value -> $new_value"
            GLOBAL_ENV_UPDATED=1
        fi
    done <<'EOF_EASYTIER_PORTS'
EASYTIER_PORT|11010|7005
EASYTIER_RPC_PORT|15888|7006
EASYTIER_WEB_PORT|11211|7007
EASYTIER_CONFIG_PORT|22020|7008
EOF_EASYTIER_PORTS

    line="$(run_root grep -E '^EASYTIER_WEB_API_HOST=' "$GLOBAL_ENV" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$line" ]; then
        value="${line#*=}"
        case "$value" in
            *:11211)
                value="${value%:11211}:7007"
                set_config_line "$GLOBAL_ENV" EASYTIER_WEB_API_HOST "EASYTIER_WEB_API_HOST=$value"
                echo "已迁移 EasyTier Web 地址端口：11211 -> 7007"
                GLOBAL_ENV_UPDATED=1
                ;;
        esac
    fi

    line="$(run_root grep -E '^EASYTIER_CONFIG_SERVER=' "$GLOBAL_ENV" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$line" ]; then
        value="${line#*=}"
        case "$value" in
            *:22020/*)
                value="$(printf '%s' "$value" | sed 's/:22020\//:7008\//')"
                set_config_line "$GLOBAL_ENV" EASYTIER_CONFIG_SERVER "EASYTIER_CONFIG_SERVER=$value"
                echo "已迁移 EasyTier Config Server 地址端口：22020 -> 7008"
                GLOBAL_ENV_UPDATED=1
                ;;
        esac
    fi
}

migrate_sensitive_env_keys() {
    local key line value secret_line secret_value
    for key in "${SENSITIVE_ENV_KEYS[@]}"; do
        line="$(run_root grep -E "^$key=" "$GLOBAL_ENV" 2>/dev/null | tail -n 1 || true)"
        [ -n "$line" ] || continue
        value="${line#*=}"
        secret_line="$(run_root grep -E "^$key=" "$GLOBAL_SECRETS" 2>/dev/null | tail -n 1 || true)"
        secret_value="${secret_line#*=}"
        if [ -n "$value" ] || [ -z "$secret_line" ] || [ -z "$secret_value" ]; then
            set_config_line "$GLOBAL_SECRETS" "$key" "$line"
        fi
        run_root sed -i "/^$key=/d" "$GLOBAL_ENV"
        echo "已迁移敏感配置：$key -> .secrets"
        GLOBAL_ENV_UPDATED=1
    done
}

ensure_global_env() {
    run_root mkdir -p "$SOFTWARE_ROOT" "$GLOBAL_ENV_DIR"
    migrate_global_env_path

    if [ ! -f "$GLOBAL_ENV" ]; then
        [ -f "$GLOBAL_ENV_EXAMPLE" ] || {
            echo "统一环境变量模板不存在：$GLOBAL_ENV_EXAMPLE" >&2
            return 1
        }

        run_root cp "$GLOBAL_ENV_EXAMPLE" "$GLOBAL_ENV"
        run_root sed -i "s#^SOFTWARE_ROOT=.*#SOFTWARE_ROOT=$SOFTWARE_ROOT#" "$GLOBAL_ENV"
        run_root chmod 0600 "$GLOBAL_ENV"
        migrate_legacy_envs

        echo "已创建普通配置：$GLOBAL_ENV"
        GLOBAL_ENV_CREATED=1
    fi

    if [ ! -f "$GLOBAL_SECRETS" ]; then
        [ -f "$GLOBAL_SECRETS_EXAMPLE" ] || { echo "敏感配置模板不存在：$GLOBAL_SECRETS_EXAMPLE" >&2; return 1; }
        run_root cp "$GLOBAL_SECRETS_EXAMPLE" "$GLOBAL_SECRETS"
        echo "已创建敏感配置：$GLOBAL_SECRETS"
        GLOBAL_SECRETS_CREATED=1
    fi

    sync_template_keys "$GLOBAL_ENV_EXAMPLE" "$GLOBAL_ENV" ".env"
    sync_template_keys "$GLOBAL_SECRETS_EXAMPLE" "$GLOBAL_SECRETS" ".secrets"
    migrate_easytier_default_ports
    migrate_sensitive_env_keys
    remove_deprecated_env_keys
    run_root chown root:root "$GLOBAL_ENV" "$GLOBAL_SECRETS"
    run_root chmod 0600 "$GLOBAL_ENV" "$GLOBAL_SECRETS"

    if [ "$GLOBAL_ENV_CREATED" -eq 1 ] || [ "$GLOBAL_SECRETS_CREATED" -eq 1 ]; then
        echo "请检查并填写："
        echo "  普通配置: $GLOBAL_ENV"
        echo "  敏感配置: $GLOBAL_SECRETS"
    fi
}

discover_tasks() {
    local installer task
    for installer in "$ROOT_DIR"/*/deploy/install.sh; do
        [ -f "$installer" ] || continue
        task="$(basename "$(dirname "$(dirname "$installer")")")"
        printf '%s\n' "$task"
    done | sort
}

load_tasks() {
    mapfile -t TASKS < <(discover_tasks)
    if [ "${#TASKS[@]}" -eq 0 ]; then
        echo "没有发现可安装业务：期望目录结构为 <业务类型>/deploy/install.sh" >&2
        exit 1
    fi
}

list_tasks() {
    local i
    load_tasks
    printf '\n%-5s %s\n' '编号' '业务类型'
    for i in "${!TASKS[@]}"; do
        printf '%-5s %s\n' "$((i + 1))" "${TASKS[$i]}"
    done
}

resolve_task() {
    local choice="$1" i
    load_tasks

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#TASKS[@]}" ]; then
            printf '%s\n' "${TASKS[$((choice - 1))]}"
            return 0
        fi
    fi

    for i in "${TASKS[@]}"; do
        if [ "$choice" = "$i" ]; then
            printf '%s\n' "$i"
            return 0
        fi
    done

    echo "未知业务类型：$choice" >&2
    return 1
}

sync_task() {
    local task="$1"
    local source_dir="$ROOT_DIR/$task"
    local target_dir="$SOFTWARE_ROOT/$task"
    local archive

    [ -d "$source_dir" ] || {
        echo "源目录不存在：$source_dir" >&2
        return 1
    }

    if ! command -v tar >/dev/null 2>&1; then
        echo "缺少 tar，无法同步部署文件。" >&2
        return 1
    fi

    archive="$(mktemp "/tmp/deploy-${task}.XXXXXX.tar")"
    trap "rm -f '$archive'" EXIT

    # 仓库只是安装源；运行时敏感配置和持久化数据不从仓库覆盖。
    tar \
        --exclude='./deploy/.env' \
        --exclude='./deploy/.secrets' \
        --exclude='./data' \
        --exclude='./state' \
        --exclude='./workspace' \
        --exclude='./backup' \
        -C "$source_dir" -cf "$archive" .

    run_root mkdir -p "$target_dir"
    run_root tar -C "$target_dir" -xf "$archive"

    if [ -f "$target_dir/deploy/install.sh" ]; then
        run_root chmod +x "$target_dir/deploy/install.sh"
    fi
    if [ -f "$target_dir/deploy/update.sh" ]; then
        run_root chmod +x "$target_dir/deploy/update.sh"
    fi

    rm -f "$archive"
    trap - EXIT

    echo "已同步：$source_dir -> $target_dir"
}

run_task() {
    local task="$1"
    local action="${2:-install}"
    local target_dir="$SOFTWARE_ROOT/$task"
    local script

    case "$action" in
        install|up)
            script="$target_dir/deploy/install.sh"
            ;;
        update|pull)
            script="$target_dir/deploy/update.sh"
            ;;
        sync)
            sync_task "$task"
            return 0
            ;;
        *)
            echo "不支持的操作：$action" >&2
            echo "支持：install / update / sync" >&2
            return 1
            ;;
    esac

    sync_task "$task"

    ensure_global_env
    if [ "$GLOBAL_ENV_CREATED" -eq 1 ] || [ "$GLOBAL_SECRETS_CREATED" -eq 1 ]; then
        return 2
    fi

    if [ ! -f "$script" ]; then
        if [ "$action" = "update" ] || [ "$action" = "pull" ]; then
            echo "该业务没有 update.sh：$script" >&2
            echo "可执行：bash deploy.sh $task install" >&2
        else
            echo "安装脚本不存在：$script" >&2
        fi
        return 1
    fi

    echo "执行：$script"
    run_root bash "$script"
}

interactive() {
    local choice task action

    list_tasks
    printf '\n仓库位置：%s\n' "$ROOT_DIR"
    printf '安装根目录：%s/<业务类型>\n\n' "$SOFTWARE_ROOT"
    read -r -p '请选择业务编号或名称（0 退出）：' choice || return 0

    case "$choice" in
        0|q|quit) return 0 ;;
    esac

    task="$(resolve_task "$choice")" || return 1
    read -r -p '操作 install/update/sync（默认 install）：' action || return 0
    run_task "$task" "${action:-install}"
}

main() {
    case "${1:-}" in
        -h|--help|help)
            usage
            ;;
        list)
            list_tasks
            ;;
        env)
            ensure_global_env || return $?
            if [ "$GLOBAL_ENV_CREATED" -eq 1 ] || [ "$GLOBAL_SECRETS_CREATED" -eq 1 ]; then
                echo "统一配置已创建：$GLOBAL_ENV / $GLOBAL_SECRETS"
            elif [ "$GLOBAL_ENV_UPDATED" -eq 1 ]; then
                echo "统一配置已更新：$GLOBAL_ENV / $GLOBAL_SECRETS"
            else
                echo "统一配置已是最新：$GLOBAL_ENV / $GLOBAL_SECRETS"
            fi
            ;;
        '')
            interactive
            ;;
        *)
            if [ "$#" -gt 2 ]; then
                usage >&2
                return 1
            fi
            local task
            task="$(resolve_task "$1")" || return 1
            run_task "$task" "${2:-install}"
            ;;
    esac
}

initialize_paths
main "$@"
