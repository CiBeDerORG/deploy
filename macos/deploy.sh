#!/usr/bin/env bash
# macOS Docker Desktop 部署入口。使用系统自带 Bash 3.2，不通过 sudo 调用 Docker。
set -euo pipefail
umask 077

die() { printf 'macOS 部署：%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "本入口仅支持 macOS"
[[ "$(id -u)" -ne 0 ]] || die "请用普通登录用户执行 bash deploy.sh，不要 sudo（Docker Desktop 属于用户会话）"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOFTWARE_ROOT="\${SOFTWARE_ROOT:-/opt/software}"
[[ "$SOFTWARE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "SOFTWARE_ROOT 必须是无空格的安全绝对路径"
case "/$SOFTWARE_ROOT/" in *"/../"*|*"/./"*|*"//"*) die "SOFTWARE_ROOT 包含非规范化路径" ;; esac
[[ "$SOFTWARE_ROOT" != / ]] || die "不能将软件根目录设为 /"
[[ ! -L "$SOFTWARE_ROOT" ]] || die "SOFTWARE_ROOT 不能是符号链接"
ENV_DIR="$SOFTWARE_ROOT/deploy"
ENV_FILE="$ENV_DIR/.env"
SECRETS_FILE="$ENV_DIR/.secrets"

usage() {
    cat <<'HELP'
macOS 通用部署命令（请用普通用户运行，不要 sudo）：
  bash deploy.sh list
  bash deploy.sh env
  bash deploy.sh <应用> sync
  bash deploy.sh easynettopo install|update|uninstall
  bash deploy.sh portainer install|update|uninstall

默认 SOFTWARE_ROOT=/opt/software，可用 SOFTWARE_ROOT=/绝对路径 覆盖。
仅已通过 macOS 适配的应用允许 install/update/uninstall。
Linux/FnOS 原安装脚本不在 macOS 上执行。
HELP
}

ensure_root_writable() {
    if [[ ! -d "$SOFTWARE_ROOT" ]]; then
        mkdir -p "$SOFTWARE_ROOT" 2>/dev/null ||
            die "无法创建 $SOFTWARE_ROOT。请先执行：sudo mkdir -p '$SOFTWARE_ROOT' && sudo chown \"$(id -u):$(id -g)\" '$SOFTWARE_ROOT'"
    fi
    [[ -d "$SOFTWARE_ROOT" && -w "$SOFTWARE_ROOT" ]] ||
        die "$SOFTWARE_ROOT 不可写；请把该目录授权给当前登录用户，不要使用 sudo 运行部署"
}

# 只校验 KEY=VALUE 名称和重复键，不 source 用户配置、也不输出密码。
validate_env() {
    awk '
      {
        s=$0; sub(/\r$/, "", s); sub(/^[[:space:]]*/, "", s)
        if (s == "" || s ~ /^#/) next
        n=index(s, "="); if (!n) exit 1
        k=substr(s, 1, n-1); sub(/[[:space:]]*$/, "", k)
        if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || seen[k]++) exit 1
      }
    ' "$1" || die "配置包含无效或重复键：$1"
}

create_env_file() {
    local source="$1" target="$2" tmp
    [[ ! -L "$target" ]] || die "不接受符号链接配置文件：$target"
    if [[ ! -e "$target" ]]; then
        tmp="$(mktemp "$target.tmp.XXXXXXXX")" || die "无法创建配置临时文件"
        if [[ "$target" == "$ENV_FILE" ]]; then
            awk -v root="$SOFTWARE_ROOT" '/^SOFTWARE_ROOT=/{print "SOFTWARE_ROOT=" root; next} {print}' "$source" > "$tmp"
        else
            cat "$source" > "$tmp"
        fi
        chmod 0600 "$tmp"
        mv "$tmp" "$target"
        echo "已创建：$target"
    fi
    [[ -f "$target" && ! -L "$target" ]] || die "配置必须是普通文件：$target"
    [[ "$(stat -f '%Lp' "$target")" == 600 ]] || die "配置文件权限必须为 0600：$target"
    [[ "$(stat -f '%u' "$target")" == "$(id -u)" ]] || die "配置必须归当前用户所有：$target"
    validate_env "$target"
    # 仅补齐缺失键，绝不覆盖用户已有配置值。
    local line key
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="\${line%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if ! grep -Eq "^[[:space:]]*$key[[:space:]]*=" "$target"; then
            if [[ "$key" == SOFTWARE_ROOT ]]; then line="SOFTWARE_ROOT=$SOFTWARE_ROOT"; fi
            printf '%s\n' "$line" >> "$target"
            printf '已补充配置项：%s\n' "$key"
        fi
    done < "$source"
}

ensure_env() {
    ensure_root_writable
    [[ ! -L "$ENV_DIR" ]] || die "统一配置目录不能是符号链接"
    mkdir -p "$ENV_DIR"
    create_env_file "$ROOT_DIR/.env.example" "$ENV_FILE"
    create_env_file "$ROOT_DIR/.secrets.example" "$SECRETS_FILE"
    local configured
    configured="$(awk -F= '$1 == "SOFTWARE_ROOT" {print substr($0, index($0,"=")+1)}' "$ENV_FILE")"
    configured="\${configured#\"}"; configured="\${configured%\"}"
    [[ "$configured" == "$SOFTWARE_ROOT" ]] ||
        die "配置中的 SOFTWARE_ROOT=$configured 与实际 $SOFTWARE_ROOT 不一致，请先人工迁移整个软件目录"
}

task_exists() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ && -f "$ROOT_DIR/$1/deploy/install.sh" ]]
}

list_tasks() {
    local installer task available
    printf '%-28s %s\n' '应用' 'macOS 支持'
    for installer in "$ROOT_DIR"/*/deploy/install.sh; do
        [[ -f "$installer" ]] || continue
        task="$(basename "$(dirname "$(dirname "$installer")")")"
        case "$task" in
            easynettopo|portainer) available="安装/更新/卸载/同步" ;;
            *) available="仅同步；原生或 Docker 安装尚未适配" ;;
        esac
        printf '%-28s %s\n' "$task" "$available"
    done
}

sync_task() {
    local task="$1" src="$ROOT_DIR/$task" dst="$SOFTWARE_ROOT/$task"
    task_exists "$task" || die "不存在应用：$task"
    ensure_env
    [[ ! -L "$dst" ]] || die "拒绝覆盖符号链接应用目录：$dst"
    mkdir -p "$dst" "$ENV_DIR/lib"
    command -v rsync >/dev/null 2>&1 || die "需要系统 rsync"
    # 不清空目标目录，不覆盖业务数据、凭据或用户配置。
    rsync -a \
        --exclude '/.git/' \
        --exclude '/data/' --exclude '/state/' --exclude '/workspace/' \
        --exclude '/backup/' --exclude '/ssh/' --exclude '/config/' \
        --exclude '/deploy/.env' --exclude '/deploy/.secrets' \
        "$src/" "$dst/"
    rsync -a "$ROOT_DIR/lib/" "$ENV_DIR/lib/"
    echo "已同步应用代码：$dst（保留运行数据及配置）"
}

action="\${2:-install}"
case "\${1:-}" in
    ''|-h|--help|help) usage ;;
    list)
        [[ "$#" -eq 1 ]] || die "list 不接受额外参数"
        list_tasks ;;
    env)
        [[ "$#" -eq 1 ]] || die "env 不接受额外参数"
        ensure_env ;;
    *)
        [[ "$#" -le 2 ]] || die "参数过多"
        task="$1"
        task_exists "$task" || die "未知应用：$task"
        case "$action" in
            sync) sync_task "$task" ;;
            install|update|uninstall)
                case "$task" in
                    easynettopo|portainer) ;;
                    *) die "$task 暂未适配 macOS 安装，请勿直接运行它的 Linux/systemd 安装脚本（可使用 sync）" ;;
                esac
                ensure_env
                if [[ "$action" != uninstall ]]; then sync_task "$task"; fi
                command -v docker >/dev/null 2>&1 || die "未找到 Docker CLI，请先启动 Docker Desktop"
                docker info >/dev/null 2>&1 || die "Docker Desktop Engine 不可用，请先启动 Docker Desktop"
                docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2"
                command -v lockf >/dev/null 2>&1 || die "系统缺少 lockf，无法安全执行并发部署"
                mkdir -p "$ENV_DIR/state"
                # macOS 自带 lockf：锁文件保留，确保并发部署不会互相覆盖。
                lockf -k -t 0 "$ENV_DIR/state/$task.macos.lock" /bin/bash \
                    "$ROOT_DIR/macos/compose-install.sh" "$task" "$action" "$SOFTWARE_ROOT" ;;
            *) die "不支持操作：$action" ;;
        esac ;;
esac
