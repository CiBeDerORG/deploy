#!/usr/bin/env bash
# GITHUB520_HOSTS_SCRIPT=1
# Linux GitHub520 Hosts 自动更新工具

set -Eeuo pipefail

readonly SOURCE_URL="https://raw.hellogithub.com/hosts"
readonly INSTALL_PATH="/usr/local/sbin/github520-hosts"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly SYSTEMD_SERVICE="$SYSTEMD_DIR/github520-hosts.service"
readonly SYSTEMD_TIMER="$SYSTEMD_DIR/github520-hosts.timer"
readonly CRON_FILE="/etc/cron.d/github520-hosts"
readonly SCRIPT_SIGNATURE="# GITHUB520_HOSTS_SCRIPT=1"
readonly MANAGED_MARKER="# Managed by github520-hosts.sh. Do not edit manually."

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/github520-hosts}"
TEMP_FILE=""
declare -a TEMP_FILES=()

cleanup() {
    local file
    for file in "${TEMP_FILES[@]}"; do
        [ -n "$file" ] && rm -f -- "$file"
    done
}
trap cleanup EXIT

log() {
    printf '[GitHub520] %s\n' "$*"
}

die() {
    log "错误：$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Linux GitHub520 Hosts 自动更新

用法：
  sudo bash github520-hosts.sh install    安装并立即更新，每小时自动检查更新
  sudo github520-hosts update             立即更新 Hosts
  sudo github520-hosts status             查看当前状态
  sudo github520-hosts uninstall          停止自动更新并移除 GitHub520 Hosts 区块

说明：
  - 数据源：https://raw.hellogithub.com/hosts
  - 优先使用 systemd timer；没有 systemd 时使用 /etc/cron.d。
  - 只维护 GitHub520 标记区块，不覆盖 /etc/hosts 的其他内容。
  - 每次实际修改前都会备份原 Hosts 文件。
  - 可通过 HOSTS_FILE、BACKUP_DIR 环境变量指定测试文件和备份目录。
EOF
}

create_temp() {
    local template="$1"
    TEMP_FILE="$(mktemp "$template")" || die "无法创建临时文件：$template"
    TEMP_FILES+=("$TEMP_FILE")
}

require_root() {
    [ "$EUID" -eq 0 ] || die "此操作需要 root 权限，请使用 sudo。"
}

validate_download() {
    awk '
        function valid_ipv4(ip, octets, count, i) {
            count = split(ip, octets, /\./)
            if (count != 4) {
                return 0
            }
            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/ || octets[i] + 0 > 255) {
                    return 0
                }
            }
            return 1
        }

        {
            line = tolower($0)

            if (line == "# github520 host start") {
                starts++
                if (state != 0) {
                    invalid = 1
                }
                state = 1
                next
            }

            if (line == "# github520 host end") {
                ends++
                if (state != 1) {
                    invalid = 1
                }
                state = 2
                next
            }

            if (state == 1) {
                if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
                    next
                }

                ip = $1
                host = $2

                if (valid_ipv4(ip) == 0 &&
                    !(index(ip, ":") > 0 && ip ~ /^[[:xdigit:]:.]+$/)) {
                    invalid = 1
                }
                if (host !~ /^[[:alnum:]][[:alnum:].-]*[[:alnum:]]$/ || NF < 2) {
                    invalid = 1
                }
                entries++
            }
        }

        END {
            if (starts != 1 || ends != 1 || state != 2 || invalid || entries < 5) {
                exit 1
            }
            print entries
        }
    ' "$1"
}

validate_existing_block() {
    awk '
        {
            line = tolower($0)

            if (line == "# github520 host start") {
                starts++
                if (state != 0) {
                    invalid = 1
                }
                state = 1
                next
            }

            if (line == "# github520 host end") {
                ends++
                if (state != 1) {
                    invalid = 1
                }
                state = 2
                next
            }
        }

        END {
            if (starts == 0 && ends == 0) {
                exit 0
            }
            if (starts == 1 && ends == 1 && state == 2 && !invalid) {
                exit 0
            }
            exit 1
        }
    ' "$1"
}

extract_block() {
    awk '
        {
            line = tolower($0)

            if (line == "# github520 host start") {
                inside = 1
                print
                next
            }

            if (inside) {
                print
            }

            if (line == "# github520 host end") {
                inside = 0
            }
        }
    ' "$1" > "$2"
}

strip_existing_block() {
    awk '
        {
            line = tolower($0)

            if (line == "# github520 host start") {
                inside = 1
                next
            }

            if (line == "# github520 host end") {
                inside = 0
                next
            }

            if (!inside) {
                print
            }
        }
    ' "$1" > "$2"
}

download_block() {
    local raw_file normalized_file block_file size

    create_temp "${TMPDIR:-/tmp}/github520-hosts.download.XXXXXX"
    raw_file="$TEMP_FILE"

    create_temp "${TMPDIR:-/tmp}/github520-hosts.normalized.XXXXXX"
    normalized_file="$TEMP_FILE"

    create_temp "${TMPDIR:-/tmp}/github520-hosts.block.XXXXXX"
    block_file="$TEMP_FILE"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error \
            --retry 2 --connect-timeout 10 --max-time 60 \
            --max-filesize 1048576 \
            --output "$raw_file" "$SOURCE_URL" ||
            die "下载 GitHub520 Hosts 失败。"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --quiet \
            --output-document="$raw_file" "$SOURCE_URL" ||
            die "下载 GitHub520 Hosts 失败。"
    else
        die "缺少 curl 或 wget，请先安装其中一个。"
    fi

    [ -s "$raw_file" ] || die "下载结果为空，已放弃更新。"
    size="$(wc -c < "$raw_file")"
    [ "$size" -le 1048576 ] || die "下载内容超过 1 MiB，已放弃更新。"

    # 统一换行符，兼容上游返回 CRLF。
    sed 's/\r$//' "$raw_file" > "$normalized_file"

    validate_download "$normalized_file" >/dev/null ||
        die "Hosts 内容校验失败（标记区块、IP 或域名格式异常），已保留旧配置。"

    extract_block "$normalized_file" "$block_file"
    [ -s "$block_file" ] || die "未能提取 GitHub520 标记区块。"

    printf '%s\n' "$block_file"
}

backup_hosts() {
    local backup_file timestamp

    install -d -m 0700 -- "$BACKUP_DIR" ||
        die "无法创建备份目录：$BACKUP_DIR"

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    backup_file="$BACKUP_DIR/hosts.$timestamp.bak"
    if [ -e "$backup_file" ]; then
        backup_file="$backup_file.$$.bak"
    fi

    cp -a -- "$HOSTS_FILE" "$backup_file" ||
        die "备份 Hosts 文件失败。"
    chmod 0600 -- "$backup_file" ||
        die "无法设置备份文件权限。"

    log "已备份原文件：$backup_file"
}

replace_hosts_block() {
    local block_file="$1"
    local new_hosts stripped_hosts

    create_temp "$HOSTS_FILE.github520.XXXXXX"
    new_hosts="$TEMP_FILE"

    create_temp "${TMPDIR:-/tmp}/github520-hosts.preserved.XXXXXX"
    stripped_hosts="$TEMP_FILE"

    # 先复制属性，再写入新内容，最后在同一目录原子替换。
    cp -a -- "$HOSTS_FILE" "$new_hosts" ||
        die "无法准备 Hosts 临时文件。"
    strip_existing_block "$HOSTS_FILE" "$stripped_hosts"
    cat "$stripped_hosts" > "$new_hosts" ||
        die "无法写入 Hosts 临时文件。"

    if [ -s "$stripped_hosts" ]; then
        printf '\n' >> "$new_hosts"
    fi

    if [ -n "$block_file" ]; then
        cat "$block_file" >> "$new_hosts" ||
            die "无法写入 GitHub520 区块。"
    fi

    mv -f -- "$new_hosts" "$HOSTS_FILE" ||
        die "替换 Hosts 文件失败，原文件仍保留。"
}

update_hosts() {
    local block_file current_block entries

    [ -f "$HOSTS_FILE" ] || die "Hosts 文件不存在：$HOSTS_FILE"
    [ ! -L "$HOSTS_FILE" ] || die "Hosts 文件是符号链接，为避免误改目标文件已停止。"
    [ -r "$HOSTS_FILE" ] && [ -w "$HOSTS_FILE" ] ||
        die "Hosts 文件不可读写：$HOSTS_FILE"

    validate_existing_block "$HOSTS_FILE" ||
        die "现有 GitHub520 标记区块不完整或重复，已停止修改以保护原文件。"

    block_file="$(download_block)"

    create_temp "${TMPDIR:-/tmp}/github520-hosts.current.XXXXXX"
    current_block="$TEMP_FILE"
    extract_block "$HOSTS_FILE" "$current_block"

    if [ -s "$current_block" ] && cmp -s "$current_block" "$block_file"; then
        log "Hosts 内容没有变化，无需写入。"
        return 0
    fi

    entries="$(awk '
        $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { count++ }
        END { print count + 0 }
    ' "$block_file")"

    backup_hosts
    replace_hosts_block "$block_file"
    log "更新成功：写入 $entries 条 Hosts 记录。"
}

remove_hosts_block() {
    local current_block

    [ -f "$HOSTS_FILE" ] || die "Hosts 文件不存在：$HOSTS_FILE"
    [ ! -L "$HOSTS_FILE" ] || die "Hosts 文件是符号链接，为避免误改目标文件已停止。"

    validate_existing_block "$HOSTS_FILE" ||
        die "现有 GitHub520 标记区块不完整或重复，未修改 Hosts 文件。"

    create_temp "${TMPDIR:-/tmp}/github520-hosts.current.XXXXXX"
    current_block="$TEMP_FILE"
    extract_block "$HOSTS_FILE" "$current_block"

    if [ ! -s "$current_block" ]; then
        log "Hosts 中没有 GitHub520 区块，无需清理。"
        return 0
    fi

    backup_hosts
    replace_hosts_block ""
    log "已移除 GitHub520 Hosts 区块，其他 Hosts 内容保持不变。"
}

assert_managed_or_absent() {
    local path="$1"

    if [ -e "$path" ] && ! grep -Fq "$MANAGED_MARKER" "$path"; then
        die "目标文件已存在且不属于本脚本，拒绝覆盖：$path"
    fi
}

write_systemd_schedule() {
    local service_tmp timer_tmp

    mkdir -p "$SYSTEMD_DIR"
    assert_managed_or_absent "$SYSTEMD_SERVICE"
    assert_managed_or_absent "$SYSTEMD_TIMER"

    create_temp "$SYSTEMD_DIR/.github520-hosts.service.XXXXXX"
    service_tmp="$TEMP_FILE"
    cat > "$service_tmp" <<EOF
$MANAGED_MARKER
[Unit]
Description=Update GitHub520 Hosts

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH update
EOF
    chmod 0644 "$service_tmp"
    mv -f -- "$service_tmp" "$SYSTEMD_SERVICE"

    create_temp "$SYSTEMD_DIR/.github520-hosts.timer.XXXXXX"
    timer_tmp="$TEMP_FILE"
    cat > "$timer_tmp" <<EOF
$MANAGED_MARKER
[Unit]
Description=Hourly GitHub520 Hosts update

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true
Unit=github520-hosts.service

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$timer_tmp"
    mv -f -- "$timer_tmp" "$SYSTEMD_TIMER"

    systemctl daemon-reload ||
        die "systemd daemon-reload 失败。"
    systemctl enable --now github520-hosts.timer ||
        die "systemd timer 启用失败。"

    remove_managed_cron
    log "已启用 systemd timer：每小时自动检查一次。"
}

write_cron_schedule() {
    local cron_tmp

    [ -d /etc/cron.d ] || die "系统没有 /etc/cron.d，无法配置 cron 自动更新。"
    command -v crontab >/dev/null 2>&1 ||
        die "未检测到 cron，请安装 cron/cronie 后重试。"

    assert_managed_or_absent "$CRON_FILE"

    create_temp "/etc/cron.d/.github520-hosts.XXXXXX"
    cron_tmp="$TEMP_FILE"
    cat > "$cron_tmp" <<EOF
$MANAGED_MARKER
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root $INSTALL_PATH update
EOF
    chmod 0644 "$cron_tmp"
    mv -f -- "$cron_tmp" "$CRON_FILE"

    # 某些精简系统安装 cron 后服务未启动，尝试启动常见服务名。
    if command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 ||
            service crond start >/dev/null 2>&1 ||
            true
    fi

    remove_managed_systemd
    log "已写入 cron：每小时第 17 分钟自动检查一次。"
}

remove_managed_cron() {
    if [ -f "$CRON_FILE" ] && grep -Fq "$MANAGED_MARKER" "$CRON_FILE"; then
        rm -f -- "$CRON_FILE"
    fi
}

remove_managed_systemd() {
    local changed=0

    if [ -f "$SYSTEMD_TIMER" ] && grep -Fq "$MANAGED_MARKER" "$SYSTEMD_TIMER"; then
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl disable --now github520-hosts.timer >/dev/null 2>&1 || true
        fi
        rm -f -- "$SYSTEMD_TIMER"
        changed=1
    fi

    if [ -f "$SYSTEMD_SERVICE" ] && grep -Fq "$MANAGED_MARKER" "$SYSTEMD_SERVICE"; then
        rm -f -- "$SYSTEMD_SERVICE"
        changed=1
    fi

    if [ "$changed" -eq 1 ] &&
        command -v systemctl >/dev/null 2>&1 &&
        [ -d /run/systemd/system ]; then
        systemctl daemon-reload || log "警告：systemd daemon-reload 失败，请手动检查。"
    fi
}

configure_schedule() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        write_systemd_schedule
    else
        write_cron_schedule
    fi
}

install_self() {
    local install_dir

    [ -f "$SCRIPT_PATH" ] || die "无法定位当前脚本文件。"
    install_dir="$(dirname "$INSTALL_PATH")"
    install -d -m 0755 -- "$install_dir"

    if [ -e "$INSTALL_PATH" ]; then
        if [ "$SCRIPT_PATH" -ef "$INSTALL_PATH" ]; then
            return 0
        fi
        grep -Fq "$SCRIPT_SIGNATURE" "$INSTALL_PATH" ||
            die "安装目标已存在且不是本脚本，拒绝覆盖：$INSTALL_PATH"
    fi

    install -m 0755 -- "$SCRIPT_PATH" "$INSTALL_PATH" ||
        die "安装脚本失败：$INSTALL_PATH"
    log "脚本已安装：$INSTALL_PATH"
}

show_status() {
    local current_block entries enabled active

    log "Hosts 文件：$HOSTS_FILE"

    if [ ! -f "$HOSTS_FILE" ]; then
        log "Hosts 文件不存在。"
    elif ! validate_existing_block "$HOSTS_FILE"; then
        log "GitHub520 区块：标记异常，请检查 Hosts 文件。"
    else
        create_temp "${TMPDIR:-/tmp}/github520-hosts.status.XXXXXX"
        current_block="$TEMP_FILE"
        extract_block "$HOSTS_FILE" "$current_block"

        if [ -s "$current_block" ]; then
            entries="$(awk '
                $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { count++ }
                END { print count + 0 }
            ' "$current_block")"
            log "GitHub520 区块：已安装（$entries 条记录）。"
        else
            log "GitHub520 区块：未安装。"
        fi
    fi

    if [ -f "$SYSTEMD_TIMER" ] && grep -Fq "$MANAGED_MARKER" "$SYSTEMD_TIMER"; then
        enabled="未知"
        active="未知"
        if command -v systemctl >/dev/null 2>&1; then
            enabled="$(systemctl is-enabled github520-hosts.timer 2>/dev/null || true)"
            active="$(systemctl is-active github520-hosts.timer 2>/dev/null || true)"
        fi
        log "自动更新：systemd timer（启用：${enabled:-未知}；运行：${active:-未知}）。"
    elif [ -f "$CRON_FILE" ] && grep -Fq "$MANAGED_MARKER" "$CRON_FILE"; then
        log "自动更新：cron（每小时第 17 分钟）。"
    else
        log "自动更新：未配置。"
    fi
}

uninstall_all() {
    remove_hosts_block
    remove_managed_systemd
    remove_managed_cron

    if [ -f "$INSTALL_PATH" ] && grep -Fq "$SCRIPT_SIGNATURE" "$INSTALL_PATH"; then
        if [ "$SCRIPT_PATH" -ef "$INSTALL_PATH" ]; then
            log "当前正在运行已安装脚本，脚本文件将在进程退出后移除。"
        fi
        rm -f -- "$INSTALL_PATH"
    fi

    log "卸载完成。Hosts 备份保留在：$BACKUP_DIR"
}

main() {
    case "${1:-help}" in
        -h|--help|help)
            usage
            ;;
        install)
            require_root
            install_self
            update_hosts
            configure_schedule
            ;;
        update)
            require_root
            update_hosts
            ;;
        status)
            show_status
            ;;
        uninstall)
            require_root
            uninstall_all
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
main "$@"
