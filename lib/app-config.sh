#!/usr/bin/env bash
# 应用配置的公共入口：模板只提供缺失项，旧全局配置只作为迁移来源。
deploy_config_error() { printf '应用配置错误：%s\n' "$*" >&2; return 1; }

deploy_read_config() {
    local config_path="$1" config_line config_key config_value
    [ -f "$config_path" ] || return 0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        config_line="${config_line%$'\r'}"
        config_line="${config_line#"${config_line%%[![:space:]]*}"}"
        case "$config_line" in ''|'#'*) continue ;; esac
        [[ "$config_line" == *=* ]] || { deploy_config_error "配置必须为 KEY=VALUE"; return 1; }
        config_key="${config_line%%=*}"; config_key="${config_key%"${config_key##*[![:space:]]}"}"
        [[ "$config_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { deploy_config_error "配置键不合法"; return 1; }
        config_value="${config_line#*=}"
        case "$config_value" in
            \"*) [[ ${#config_value} -ge 2 && "$config_value" == *\" ]] || return 1; config_value="${config_value:1:${#config_value}-2}" ;;
            \'*) [[ ${#config_value} -ge 2 && "$config_value" == *\' ]] || return 1; config_value="${config_value:1:${#config_value}-2}" ;;
        esac
        # 不执行配置文本，不改变凭据内部的空格、引号或 Unicode。
        export "$config_key=$config_value"
    done < "$config_path"
}

deploy_init_config_file() {
    local template="$1" legacy="$2" target="$3" staged
    [ -f "$template" ] && [ ! -L "$template" ] || { deploy_config_error "默认值模板不存在"; return 1; }
    [ ! -L "$target" ] && [ ! -L "$legacy" ] || { deploy_config_error "配置不能是符号链接"; return 1; }
    [ -e "$target" ] || (umask 077; : > "$target") || return 1
    [ -f "$target" ] || return 1
    [ ! -e "$legacy" ] || [ -f "$legacy" ] || { deploy_config_error "旧配置必须是普通文件"; return 1; }
    [ -f "$legacy" ] || legacy=/dev/null
    staged="$(mktemp "${target}.tmp.XXXXXXXX")" || return 1
    # 先完整校验再原子替换；已有配置（包括显式空值）优先，绝不删除旧文件。
    if ! awk -v template="$template" -v legacy="$legacy" -v target="$target" '
        function fail() { failed=1; exit 1 }
        {
            raw=$0; sub(/\r$/, "", raw); line=raw; sub(/^[ \t]+/, "", line)
            if (line == "" || line ~ /^#/) { if (FILENAME == target) records[++count]=$0; next }
            at=index(line,"="); if (!at) fail()
            key=substr(line,1,at-1); sub(/[ \t]+$/, "", key)
            if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || seen[FILENAME SUBSEP key]++) fail()
            value=substr(line,at+1)
            if (FILENAME == template) { keys[++n]=key; defaults[key]=value }
            else if (FILENAME == legacy) { old[key]=value; hasold[key]=1 }
            else { present[key]=1; records[++count]=$0 }
        }
        END {
            if (failed) exit 1
            for (i=1;i<=count;i++) print records[i]
            for (i=1;i<=n;i++) { key=keys[i]; if (!present[key]) print key "=" (hasold[key] ? old[key] : defaults[key]) }
        }
    ' "$template" "$legacy" "$target" > "$staged"; then
        rm -f -- "$staged"; deploy_config_error "配置格式错误或键重复，未覆盖原文件"; return 1
    fi
    chmod 0600 "$staged" && mv -f -- "$staged" "$target" || { rm -f -- "$staged"; return 1; }
}

deploy_load_app_config() {
    local config_root="$1" config_app="$2" config_base config_dir
    [[ "$config_app" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    config_base="$config_root/$config_app"; config_dir="$config_base/config"
    [ ! -L "$config_base" ] && [ ! -L "$config_dir" ] || { deploy_config_error "应用配置目录不能是符号链接"; return 1; }
    (umask 077; mkdir -p "$config_dir") || return 1
    chmod 0700 "$config_dir" || return 1
    deploy_init_config_file "$config_base/deploy/config.env.example" "$config_root/deploy/.env" "$config_dir/.env" || return 1
    deploy_init_config_file "$config_base/deploy/config.secrets.example" "$config_root/deploy/.secrets" "$config_dir/.secrets" || return 1
    # 全局普通设置用于时区、镜像源等公共能力；应用值只覆盖当前进程。
    deploy_read_config "$config_root/deploy/.env" || return 1
    ENV_FILE="$config_dir/.env"; SECRETS_FILE="$config_dir/.secrets"
    deploy_read_config "$ENV_FILE" && deploy_read_config "$SECRETS_FILE"
}
