#!/usr/bin/env bash
# Shared GHCR image routing. Source this file, then call deploy_prepare_images
# once with every remote image variable used by this install/update invocation.
# Only the two deploy-owned ordinary settings below are read; never source dotenv.

_deploy_image_error() {
    printf '镜像配置错误：%s\n' "$*" >&2
    return 1
}

_deploy_image_read_config() {
    local _dim_config_file="$1" _dim_config_source_out="$2" _dim_config_list_out="$3"
    local _dim_config_line _dim_config_key _dim_config_value _dim_config_line_no=0
    local _dim_config_source=original _dim_config_list=dockerproxy,ghproxy
    local _dim_config_source_seen=0 _dim_config_list_seen=0
    [ -f "$_dim_config_file" ] || {
        _deploy_image_error "缺少统一 .env，请先运行 sudo bash deploy.sh env"
        return 1
    }
    while IFS= read -r _dim_config_line || [ -n "$_dim_config_line" ]; do
        _dim_config_line_no=$((_dim_config_line_no + 1))
        _dim_config_line="${_dim_config_line%$'\r'}"
        _dim_config_line="${_dim_config_line#"${_dim_config_line%%[![:space:]]*}"}"
        case "$_dim_config_line" in ''|\#*) continue ;; esac
        [[ "$_dim_config_line" == *=* ]] || continue
        _dim_config_key="${_dim_config_line%%=*}"
        _dim_config_key="${_dim_config_key%"${_dim_config_key##*[![:space:]]}"}"
        case "$_dim_config_key" in
            DOCKER_IMAGE_SOURCE)
                [ "$_dim_config_source_seen" -eq 0 ] || {
                    _deploy_image_error "DOCKER_IMAGE_SOURCE 重复定义，请只保留一行"
                    return 1
                }
                _dim_config_source_seen=1
                ;;
            DOCKER_IMAGE_MIRRORS)
                [ "$_dim_config_list_seen" -eq 0 ] || {
                    _deploy_image_error "DOCKER_IMAGE_MIRRORS 重复定义，请只保留一行"
                    return 1
                }
                _dim_config_list_seen=1
                ;;
            *) continue ;;
        esac
        # These two settings are enum/list options, never credentials. Trim only
        # their formatting whitespace; all other dotenv values remain untouched.
        _dim_config_value="${_dim_config_line#*=}"
        _dim_config_value="${_dim_config_value#"${_dim_config_value%%[![:space:]]*}"}"
        _dim_config_value="${_dim_config_value%"${_dim_config_value##*[![:space:]]}"}"
        case "$_dim_config_value" in
            \"*|\'*)
                if (( ${#_dim_config_value} < 2 )) ||
                   [ "${_dim_config_value:0:1}" != "${_dim_config_value: -1}" ]; then
                    _deploy_image_error "$_dim_config_file:$_dim_config_line_no 的 $_dim_config_key 引号未闭合"
                    return 1
                fi
                _dim_config_value="${_dim_config_value:1:${#_dim_config_value}-2}"
                _dim_config_value="${_dim_config_value#"${_dim_config_value%%[![:space:]]*}"}"
                _dim_config_value="${_dim_config_value%"${_dim_config_value##*[![:space:]]}"}"
                ;;
        esac
        case "$_dim_config_key" in
            DOCKER_IMAGE_SOURCE) _dim_config_source="${_dim_config_value:-original}" ;;
            DOCKER_IMAGE_MIRRORS) _dim_config_list="${_dim_config_value:-dockerproxy,ghproxy}" ;;
        esac
    done < "$_dim_config_file"
    case "$_dim_config_source" in
        original|mirror) ;;
        *) _deploy_image_error "DOCKER_IMAGE_SOURCE 只能是 original 或 mirror（留空使用 original）"; return 1 ;;
    esac
    printf -v "$_dim_config_source_out" '%s' "$_dim_config_source"
    printf -v "$_dim_config_list_out" '%s' "$_dim_config_list"
}

_deploy_image_is_ghcr() {
    case "$1" in
        ghcr.io/*) return 0 ;;
        *) return 1 ;;
    esac
}

_deploy_image_origin() {
    local _dim_origin_ref="$1"
    # Match complete GHCR host/path boundaries only. In particular, Docker Hub
    # short names and non-GHCR proxy references must remain byte-for-byte intact.
    case "$_dim_origin_ref" in
        ghcr.io/*) ;;
        ghcr.nju.edu.cn/*|ghcr.dockerproxy.net/*|ghcr.dockerproxy.com/*|ghcr.1ms.run/*|ghcr.m.daocloud.io/*)
            _dim_origin_ref="ghcr.io/${_dim_origin_ref#*/}" ;;
        m.daocloud.io/ghcr.io/*)
            _dim_origin_ref="${_dim_origin_ref#m.daocloud.io/}" ;;
        gh-proxy.com/docker/ghcr.io/*)
            _dim_origin_ref="${_dim_origin_ref#gh-proxy.com/docker/}" ;;
        *) printf -v "$2" '%s' "$_dim_origin_ref"; return 0 ;;
    esac
    if [ "$_dim_origin_ref" = ghcr.io/ ] || [[ "$_dim_origin_ref" == *[[:space:]]* ]]; then
        _deploy_image_error "GHCR 镜像地址缺少仓库路径或包含空白"
        return 1
    fi
    printf -v "$2" '%s' "$_dim_origin_ref"
}

_deploy_image_rewrite() {
    local _dim_rewrite_provider="$1" _dim_rewrite_ref="$2" _dim_rewrite_host
    local _dim_rewrite_path="${2#*/}"
    _deploy_image_is_ghcr "$_dim_rewrite_ref" || return 1
    case "$_dim_rewrite_provider" in
        ghproxy)
            printf 'gh-proxy.com/docker/%s\n' "$_dim_rewrite_ref"
            return 0 ;;
        daocloud)
            printf 'm.daocloud.io/%s\n' "$_dim_rewrite_ref"
            return 0 ;;
        dockerproxy) _dim_rewrite_host=ghcr.dockerproxy.net ;;
        nju) _dim_rewrite_host=ghcr.nju.edu.cn ;;
        1ms) _dim_rewrite_host=ghcr.1ms.run ;;
        *) return 1 ;;
    esac
    printf '%s/%s\n' "$_dim_rewrite_host" "$_dim_rewrite_path"
}

# Run in a subshell so the lock and temporary-file trap cannot leak into
# the installer or be held throughout docker pull/build/up. Only the provider
# name goes to stdout; diagnostics go to stderr. Uses mkdir locking so the same
# mirror rotation works with macOS' built-in Bash and without util-linux flock.
_deploy_image_pick() (
    local _dim_pick_root="$1" _dim_pick_list="$2"
    local _dim_pick_item _dim_pick_previous='' _dim_pick_start=0 _dim_pick_index _dim_pick_selected
    local _dim_pick_dir="$_dim_pick_root/deploy/state" _dim_pick_file _dim_pick_temp=''
    local _dim_pick_lock_dir _dim_pick_wait=0 _dim_pick_seen_item _dim_pick_duplicate
    local _dim_pick_pid
    local -a _dim_pick_input=() _dim_pick_providers=()
    IFS=, read -r -a _dim_pick_input <<< "$_dim_pick_list"
    for _dim_pick_item in "${_dim_pick_input[@]}"; do
        _dim_pick_item="${_dim_pick_item#"${_dim_pick_item%%[![:space:]]*}"}"
        _dim_pick_item="${_dim_pick_item%"${_dim_pick_item##*[![:space:]]}"}"
        [ -n "$_dim_pick_item" ] || continue
        case "$_dim_pick_item" in
            dockerproxy|ghproxy|nju|1ms|daocloud) ;;
            *) _deploy_image_error "DOCKER_IMAGE_MIRRORS 仅支持 dockerproxy、ghproxy、nju、1ms、daocloud"; return 1 ;;
        esac
        _dim_pick_duplicate=0
        for _dim_pick_seen_item in "${_dim_pick_providers[@]}"; do
            if [ "$_dim_pick_seen_item" = "$_dim_pick_item" ]; then
                _dim_pick_duplicate=1
                break
            fi
        done
        [ "$_dim_pick_duplicate" -eq 1 ] && continue
        _dim_pick_providers+=("$_dim_pick_item")
    done
    if (( ${#_dim_pick_providers[@]} == 0 )); then
        _deploy_image_error "DOCKER_IMAGE_MIRRORS 没有有效候选站；留空可使用默认列表"
        return 1
    fi
    umask 077
    mkdir -p "$_dim_pick_dir" || { _deploy_image_error "无法创建镜像轮换状态目录"; return 1; }
    _dim_pick_file="$_dim_pick_dir/image-mirror.last"
    _dim_pick_lock_dir="$_dim_pick_dir/image-mirror.lock.d"
    while ! mkdir "$_dim_pick_lock_dir" 2>/dev/null; do
        _dim_pick_pid=''
        if [ -f "$_dim_pick_lock_dir/pid" ]; then
            IFS= read -r _dim_pick_pid < "$_dim_pick_lock_dir/pid" || true
        fi
        if [[ "$_dim_pick_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_dim_pick_pid" 2>/dev/null; then
            rm -rf "$_dim_pick_lock_dir"
            continue
        fi
        if [ "$_dim_pick_wait" -ge 10 ]; then
            _deploy_image_error "镜像轮换状态正被其他部署占用，请稍后重试"
            return 1
        fi
        sleep 1
        _dim_pick_wait=$((_dim_pick_wait + 1))
    done
    printf '%s\n' "$$" > "$_dim_pick_lock_dir/pid"
    trap 'rm -rf "$_dim_pick_lock_dir"; [ -z "${_dim_pick_temp:-}" ] || rm -f "$_dim_pick_temp"' EXIT
    if [ -f "$_dim_pick_file" ]; then
        IFS= read -r _dim_pick_previous < "$_dim_pick_file" || [ -n "$_dim_pick_previous" ] || true
    fi
    for _dim_pick_index in "${!_dim_pick_providers[@]}"; do
        if [ "${_dim_pick_providers[_dim_pick_index]}" = "$_dim_pick_previous" ]; then
            _dim_pick_start=$(((_dim_pick_index + 1) % ${#_dim_pick_providers[@]}))
            break
        fi
    done
    _dim_pick_selected="${_dim_pick_providers[_dim_pick_start]}"
    _dim_pick_temp="$(mktemp "${_dim_pick_file}.tmp.XXXXXXXX")" || {
        _deploy_image_error "无法暂存镜像轮换状态"
        return 1
    }
    if ! printf '%s\n' "$_dim_pick_selected" > "$_dim_pick_temp" ||
       ! mv -f "$_dim_pick_temp" "$_dim_pick_file"; then
        _deploy_image_error "无法保存镜像轮换状态"
        return 1
    fi
    _dim_pick_temp=''
    printf '%s\n' "$_dim_pick_selected"
)

# Do not accept inherited environment as a prepared deployment. Cached choices
# remain in this Bash process only and are checked against the current Bash process and root.
_DEPLOY_IMAGE_PICK_PID=''
_DEPLOY_IMAGE_PICK_ROOT=''
_DEPLOY_IMAGE_PICK_LIST=''
_DEPLOY_IMAGE_PICK_PROVIDER=''
export -n _DEPLOY_IMAGE_PICK_PID _DEPLOY_IMAGE_PICK_ROOT _DEPLOY_IMAGE_PICK_LIST _DEPLOY_IMAGE_PICK_PROVIDER

deploy_prepare_images() {
    if (( $# < 3 )); then
        _deploy_image_error "deploy_prepare_images 需要软件根目录、.env 路径和远端镜像变量名"
        return 1
    fi
    local _dim_root="$1" _dim_env_file="$2"
    shift 2
    local _dim_source _dim_list _dim_name _dim_ref _dim_index _dim_provider=''
    local -a _dim_names=("$@") _dim_inputs=() _dim_origins=() _dim_remote=() _dim_results=()
    _deploy_image_read_config "$_dim_env_file" _dim_source _dim_list || return 1
    for _dim_name in "${_dim_names[@]}"; do
        if ! [[ "$_dim_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ "$_dim_name" == _dim_* ]]; then
            _deploy_image_error "远端镜像变量名不合法"
            return 1
        fi
        _dim_ref="${!_dim_name:-}"
        _dim_inputs+=("$_dim_ref")
        _deploy_image_origin "$_dim_ref" _dim_ref || return 1
        _dim_origins+=("$_dim_ref")
        if _deploy_image_is_ghcr "$_dim_ref"; then
            _dim_remote+=("$_dim_ref")
        fi
    done
    if [ "$_dim_source" = mirror ] && (( ${#_dim_remote[@]} > 0 )); then
        if [ "${_DEPLOY_IMAGE_PICK_PID:-}" = "$$" ] &&
           [ "${_DEPLOY_IMAGE_PICK_ROOT:-}" = "$_dim_root" ] &&
           [ "${_DEPLOY_IMAGE_PICK_LIST:-}" = "$_dim_list" ]; then
            _dim_provider="$_DEPLOY_IMAGE_PICK_PROVIDER"
        else
            _dim_provider="$(_deploy_image_pick "$_dim_root" "$_dim_list")" || return 1
            _DEPLOY_IMAGE_PICK_PID="$$"
            _DEPLOY_IMAGE_PICK_ROOT="$_dim_root"
            _DEPLOY_IMAGE_PICK_LIST="$_dim_list"
            _DEPLOY_IMAGE_PICK_PROVIDER="$_dim_provider"
        fi
        printf '镜像来源：加速站 %s（本次安装/更新共用；下次执行轮换）。\n' "$_dim_provider" >&2
    elif [ "$_dim_source" = mirror ]; then
        printf '镜像来源：本次没有 GHCR 镜像，保留所有原始地址，不推进加速轮换。\n' >&2
    else
        printf '镜像来源：原始仓库。\n' >&2
    fi
    for _dim_index in "${!_dim_origins[@]}"; do
        _dim_ref="${_dim_origins[_dim_index]}"
        if [ -n "$_dim_provider" ]; then
            if _deploy_image_is_ghcr "$_dim_ref"; then
                _dim_ref="$(_deploy_image_rewrite "$_dim_provider" "$_dim_ref")" || {
                    _deploy_image_error "无法转换本轮 GHCR 镜像"
                    return 1
                }
            else
                printf '镜像 %s 不属于 GHCR，保留原地址。\n' "${_dim_names[_dim_index]}" >&2
            fi
        fi
        _dim_results+=("$_dim_ref")
    done
    for _dim_index in "${!_dim_names[@]}"; do
        _dim_name="${_dim_names[_dim_index]}"
        printf -v "$_dim_name" '%s' "${_dim_results[_dim_index]}"
        export "$_dim_name"
        printf '镜像 %s：%s -> %s\n' "$_dim_name" "${_dim_inputs[_dim_index]}" "${_dim_results[_dim_index]}" >&2
    done
}
