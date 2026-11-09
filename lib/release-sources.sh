#!/usr/bin/env bash
# GitHub Release 文件来源轮换与完整性校验。所有设置只解析统一 .env，不执行配置内容。

_deploy_release_error() {
    printf 'GitHub Release 下载错误：%s\n' "$*" >&2
    return 1
}

_deploy_release_read_config() {
    local file="$1" source_name="$2" mirrors_name="$3"
    local line key value selected=mirror candidates=ghproxy,ghfast,ghproxy-net
    local source_seen=0 mirrors_seen=0
    [[ -f "$file" && ! -L "$file" ]] || {
        _deploy_release_error "统一 .env 不存在或不是普通文件：$file"
        return 1
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|\#*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        case "$key" in
            GITHUB_RELEASE_SOURCE)
                (( source_seen == 0 )) || { _deploy_release_error 'GITHUB_RELEASE_SOURCE 重复定义'; return 1; }
                source_seen=1 ;;
            GITHUB_RELEASE_MIRRORS)
                (( mirrors_seen == 0 )) || { _deploy_release_error 'GITHUB_RELEASE_MIRRORS 重复定义'; return 1; }
                mirrors_seen=1 ;;
            *) continue ;;
        esac
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
            \"*|\'*)
                if (( ${#value} < 2 )) || [[ "${value:0:1}" != "${value: -1}" ]]; then
                    _deploy_release_error "$key 引号未闭合"
                    return 1
                fi
                value="${value:1:${#value}-2}"
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%"${value##*[![:space:]]}"}"
                ;;
        esac
        case "$key" in
            GITHUB_RELEASE_SOURCE) selected="${value:-mirror}" ;;
            GITHUB_RELEASE_MIRRORS) candidates="${value:-ghproxy,ghfast,ghproxy-net}" ;;
        esac
    done < "$file"
    case "$selected" in original|mirror) ;; *) _deploy_release_error 'GITHUB_RELEASE_SOURCE 只能为 original 或 mirror'; return 1 ;; esac
    printf -v "$source_name" '%s' "$selected"
    printf -v "$mirrors_name" '%s' "$candidates"
}

_deploy_release_url() {
    local provider="$1" origin="$2"
    case "$provider" in
        original) printf '%s\n' "$origin" ;;
        ghproxy) printf 'https://gh-proxy.org/%s\n' "$origin" ;;
        ghfast) printf 'https://ghfast.top/%s\n' "$origin" ;;
        ghproxy-net) printf 'https://ghproxy.net/%s\n' "$origin" ;;
        *) _deploy_release_error '不支持的加速来源'; return 1 ;;
    esac
}

# 每次调用选择上次首选站的下一个站。锁仅在选站及写入状态时持有，不跨网络下载。
_deploy_release_order() (
    local software_root="$1" mirrors="$2" item first_index=0 previous='' i name tmp=''
    local state_dir="$software_root/deploy/state" state_file lock_fd
    local -a input=() providers=() ordered=()
    local -A seen=()
    IFS=, read -r -a input <<< "$mirrors"
    for item in "${input[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        case "$item" in ghproxy|ghfast|ghproxy-net) ;; *) _deploy_release_error "不支持的加速站：$item"; return 1 ;; esac
        [[ ${seen[$item]+present} ]] && continue
        seen[$item]=1
        providers+=("$item")
    done
    (( ${#providers[@]} > 0 )) || { _deploy_release_error '没有有效加速站'; return 1; }
    command -v flock >/dev/null 2>&1 || { _deploy_release_error '轮换需要 flock'; return 1; }
    umask 077
    mkdir -p -- "$state_dir" || { _deploy_release_error '无法创建轮换状态目录'; return 1; }
    state_file="$state_dir/github-release-mirror.last"
    exec {lock_fd}>"$state_dir/github-release-mirror.lock" || return 1
    flock -x -w 10 "$lock_fd" || { _deploy_release_error '加速站轮换锁被占用'; return 1; }
    if [[ -f "$state_file" ]]; then
        IFS= read -r previous < "$state_file" || true
    fi
    for i in "${!providers[@]}"; do
        if [[ "${providers[i]}" == "$previous" ]]; then
            first_index=$(((i + 1) % ${#providers[@]}))
            break
        fi
    done
    tmp="$(mktemp "$state_dir/.release-mirror.XXXXXXXX")" || return 1
    trap '[[ -z "$tmp" ]] || rm -f -- "$tmp"' EXIT
    printf '%s\n' "${providers[first_index]}" > "$tmp" || return 1
    mv -f -- "$tmp" "$state_file" || return 1
    tmp=''
    for (( i = 0; i < ${#providers[@]}; i++ )); do
        ordered+=("${providers[(first_index + i) % ${#providers[@]}]}")
    done
    (IFS=,; printf '%s\n' "${ordered[*]}")
)

# 将同一来源的资产和 .sha256 下载到受控目录，校验通过才返回成功。
# 遇到连接失败、状态异常、文件或校验和不匹配时自动切换下一站，最后回退 GitHub 官方。
deploy_download_github_release_pair() {
    if (( $# != 5 )); then
        _deploy_release_error '参数必须为 软件根目录 .env 路径 GitHub Release 基础地址 资产名 输出目录'
        return 1
    fi
    local root="$1" envfile="$2" base="$3" asset="$4" dest="$5"
    local source mirrors order provider url dir line digest actual
    local -a candidates=()
    if [[ ! "$base" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/(download/[A-Za-z0-9_.+-]+|latest/download)$ ]] ||
       [[ ! "$asset" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
       [[ ! -d "$dest" || -L "$dest" ]]; then
        _deploy_release_error '只支持 GitHub 官方 Release 资产及已有安全的目标目录'
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { _deploy_release_error '缺少 curl'; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { _deploy_release_error '缺少 sha256sum'; return 1; }
    _deploy_release_read_config "$envfile" source mirrors || return 1
    if [[ "$source" == mirror ]]; then
        order="$(_deploy_release_order "$root" "$mirrors")" || return 1
        IFS=, read -r -a candidates <<< "$order"
        candidates+=(original)
    else
        candidates=(original)
    fi
    for provider in "${candidates[@]}"; do
        url="$(_deploy_release_url "$provider" "$base")" || return 1
        dir="$(mktemp -d "$dest/.github-release.XXXXXXXX")" || return 1
        printf 'Release 下载：尝试 %s（%s）\n' "$provider" "$asset" >&2
        # 禁止 HTTPS 连接重定向到明文 HTTP，文件下载设置超时，避免单站长时间阻塞。
        if curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 120 \
            -o "$dir/$asset.sha256" "$url/$asset.sha256" &&
           curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 180 \
            -o "$dir/$asset" "$url/$asset" &&
           [[ "$(wc -l < "$dir/$asset.sha256")" -eq 1 ]]; then
            IFS= read -r line < "$dir/$asset.sha256" || true
            if [[ "$line" =~ ^[0-9a-fA-F]{64}[[:blank:]][[:blank:]] ]] &&
               [[ "${line:66}" == "$asset" ]]; then
                digest="${line:0:64}"
                actual="$(sha256sum -- "$dir/$asset")" || actual=''
                if [[ "${actual:0:64}" == "${digest,,}" ]]; then
                    mv -f -- "$dir/$asset.sha256" "$dest/$asset.sha256" &&
                    mv -f -- "$dir/$asset" "$dest/$asset" || {
                        rm -rf -- "$dir"
                        _deploy_release_error '无法写入已校验的安装包'
                        return 1
                    }
                    rm -rf -- "$dir"
                    printf 'Release 下载完成：%s，SHA-256 验证成功\n' "$provider" >&2
                    return 0
                fi
            fi
        fi
        rm -rf -- "$dir"
        printf 'Release 下载：%s 失败或校验不一致，切换下一来源。\n' "$provider" >&2
    done
    _deploy_release_error '全部加速站及 GitHub 官方下载均失败；原安装文件未替换'
    return 1
}
