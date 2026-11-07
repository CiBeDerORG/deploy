#!/usr/bin/env bash
# Small cross-platform helpers for the existing Deploy lifecycle scripts.
# Linux/fnOS retain their root-owned configuration model; macOS uses the
# current Docker Desktop login user and its per-user Docker socket.

deploy_is_macos() {
    [ "${EASYHOSTAGENT_PLATFORM:-}" = macos ] || [ "$(uname -s 2>/dev/null)" = Darwin ]
}

deploy_require_root() {
    if deploy_is_macos; then
        return 0
    fi
    [ "$(id -u)" -eq 0 ] && return 0
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$0" "$@"
    fi
    printf '此操作需要 root 权限，请使用 sudo 执行。\n' >&2
    return 1
}

deploy_chown_if_needed() {
    deploy_is_macos && return 0
    chown "$@"
}

deploy_secure_config_files() {
    if deploy_is_macos; then
        for file in "$@"; do
            [ -O "$file" ] || {
                printf 'macOS 配置文件必须由当前登录用户拥有：%s\n' "$file" >&2
                return 1
            }
        done
        chmod 0600 "$@"
    else
        chown root:root "$@" && chmod 0600 "$@"
    fi
}

deploy_sed_in_place() {
    if deploy_is_macos; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}
