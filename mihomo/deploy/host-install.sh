#!/usr/bin/env bash
# Build a complete native release before switching the service. Runtime, cached
# downloads, configuration copies, logs and transaction backups stay in MODULE.
set -Eeuo pipefail

host_system_unit_path() { printf '/etc/systemd/system/deploy-mihomo.service\n'; }
host_assert_platform() {
    [ "$(uname -s)" = Linux ] || die "原生模式仅支持 Linux"
    [ -d /run/systemd/system ] || die "原生模式需要 systemd 作为 PID 1"
    for cmd in systemctl git curl tar xz sha256sum awk gzip flock readlink; do
        command -v "$cmd" >/dev/null 2>&1 || die "原生安装缺少 $cmd"
    done
}
host_init_paths() {
    HERE="$(cd -- "$1" && pwd -P)"
    MODULE="$(cd -- "$HERE/.." && pwd -P)"
    ROOT="$(cd -- "$MODULE/.." && pwd -P)"
    RUNTIME="$MODULE/runtime/host"
    SERVICE=deploy-mihomo.service
    UNIT="$(host_system_unit_path)"
    UNIT_BODY="$RUNTIME/systemd/$SERVICE"
    MODULE_ID="$(printf '%s' "$MODULE" | sha256sum)"
    MODULE_ID="${MODULE_ID%% *}"
}
host_assert_unit_owner() {
    local registered candidate
    registered="$(systemctl show "$SERVICE" --property=FragmentPath --value 2>/dev/null || :)"
    if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
        candidate="$UNIT"
    elif [ -n "$registered" ]; then
        die "同名服务已由其他 unit 路径注册，拒绝接管：$registered"
    else
        if systemctl is-active --quiet "$SERVICE"; then
            die "同名服务正在运行，但未找到可验证的安装归属，拒绝接管"
        fi
        return 0
    fi
    [ -f "$candidate" ] &&
        grep -Fxq '# Managed by CiBeDerORG/deploy Mihomo native installer' "$candidate" ||
        die "同名 systemd 服务已存在且非本仓库管理，拒绝覆盖：$UNIT"
    if grep -q '^# Managed module SHA256:' "$candidate"; then
        grep -Fxq "# Managed module SHA256: $MODULE_ID" "$candidate" ||
            die "同名 Mihomo 服务属于另一个安装目录；请先明确迁移旧安装，拒绝覆盖：$MODULE"
    elif ! grep -Fxq "ExecStart=/bin/bash \"$MODULE/deploy/host-run.sh\"" "$candidate" &&
         ! grep -Fxq "ExecStart=/bin/bash $MODULE/deploy/host-run.sh" "$candidate"; then
        # Compatibility with the initial native installer, which had no owner ID.
        die "旧版 Mihomo unit 的启动路径不属于当前安装目录，拒绝覆盖：$MODULE"
    fi
}
host_set_current() {
    local target="$1" next="$RUNTIME/.current-next.$$"
    # A failed rename must not leave a staging link that blocks rollback's retry.
    rm -f -- "$next" || return 1
    ln -s -- "$target" "$next" || return 1
    if ! mv -Tf -- "$next" "$RUNTIME/current"; then
        rm -f -- "$next"
        return 1
    fi
}
host_unit_quote() {
    # systemd has its own quoting, specifier expansion and environment expansion.
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    value="${value//\$/\$\$}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    printf '"%s"' "$value"
}
host_write_unit() {
    cat > "$work/unit.new" <<EOF_UNIT
# Managed by CiBeDerORG/deploy Mihomo native installer
# Managed module SHA256: $MODULE_ID
[Unit]
Description=Deploy Mihomo + MetaCubeXD full native Web/Agent
Wants=network-online.target
After=network-online.target
RequiresMountsFor=$(host_unit_quote "$MODULE")
[Service]
Type=simple
ExecStart=/bin/bash $(host_unit_quote "$RUNTIME/current/launch/host-run.sh") $(host_unit_quote "$MODULE")
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
StandardOutput=append:${RUNTIME//%/%%}/logs/service.log
StandardError=append:${RUNTIME//%/%%}/logs/service-error.log
[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 "$work/unit.new"
}
host_snapshot_service() {
    previous=""
    previous_release=""
    previous_active=0
    previous_unit=0
    previous_body=0
    previous_enabled="$(systemctl is-enabled "$SERVICE" 2>/dev/null || :)"
    case "$previous_enabled" in
        enabled|enabled-runtime|disabled|linked|linked-runtime|static|indirect|not-found|'') ;;
        *) die "无法安全保存现有 systemd 启用状态：$previous_enabled" ;;
    esac
    if [ -L "$RUNTIME/current" ]; then
        previous="$(readlink "$RUNTIME/current")"
        previous_release="$(readlink -f "$RUNTIME/current")"
        case "$previous_release" in
            "$RUNTIME/releases/"*) [ -d "$previous_release" ] || die "旧 current 发布目录缺失" ;;
            *) die "旧 current 指向当前模块以外，拒绝覆盖" ;;
        esac
    fi
    if systemctl is-active --quiet "$SERVICE"; then previous_active=1; fi
    if (( previous_active == 1 )) && [ -z "$previous_release" ]; then
        die "服务正在运行但缺少可恢复的旧发布目录，拒绝执行不可回退的切换"
    fi
    if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
        cp -a -- "$UNIT" "$work/unit.previous"
        previous_unit=1
    fi
    if [ -e "$UNIT_BODY" ] || [ -L "$UNIT_BODY" ]; then
        cp -a -- "$UNIT_BODY" "$work/body.previous"
        previous_body=1
    fi
}
host_seal_legacy_release() {
    local node_target node_name
    [ -n "$previous_release" ] || return 0
    if [ -d "$previous_release/launch" ]; then
        [ -f "$previous_release/launch/host-run.sh" ] &&
            [ -x "$previous_release/node/bin/node" ] || die "旧版封存发布目录不完整，拒绝自动改写"
        return 0
    fi
    # deploy.sh sync has already refreshed the mirror. The known legacy bridge
    # is frozen with the OLD binaries/Node so first-upgrade rollback is usable.
    [ -f "$previous_release/server/index.mjs" ] &&
        [ -f "$previous_release/ui-dist/index.html" ] &&
        [ -x "$previous_release/mihomo" ] || die "旧版发布目录不完整，拒绝自动迁移"
    node_target="$(readlink -f "$RUNTIME/node-current")"
    case "$node_target" in
        "$RUNTIME/"node-*) ;;
        *) die "旧版 node-current 不属于当前 Mihomo runtime，拒绝自动迁移" ;;
    esac
    [ "$(dirname -- "$node_target")" = "$RUNTIME" ] && [ -x "$node_target/bin/node" ] ||
        die "旧版 Node 缺失或绑定目录异常，无法建立可靠回退版本"
    node_name="${node_target##*/}"
    mkdir -m 0700 "$work/legacy-launch"
    cp -- "$HERE/host-legacy-run.sh" "$work/legacy-launch/host-run.sh"
    cp -- "$HERE/common.sh" "$HERE/host-health.mjs" "$work/legacy-launch/"
    chmod 0700 "$work/legacy-launch/host-run.sh"
    : > "$work/legacy-launch/legacy-layout"
    if [ -e "$previous_release/node" ] || [ -L "$previous_release/node" ]; then
        [ "$(readlink -f "$previous_release/node")" = "$node_target" ] ||
            die "旧发布已有其他 Node 绑定，拒绝覆盖"
    else
        ln -s -- "../../$node_name" "$previous_release/node"
    fi
    mv -- "$work/legacy-launch" "$previous_release/launch"
}
host_wait_ready() {
    local checked_release="$1" attempt web_host core_host
    local -a health_args=()
    # Legacy releases predate the new UI/config.js acceptance gate. Recover
    # their previous service behavior without claiming they pass the new gate.
    if [ -f "$checked_release/launch/legacy-layout" ]; then health_args+=(--service-only); fi
    web_host="$MIHOMO_API_BIND_IP"
    core_host="$MIHOMO_CORE_API_BIND_IP"
    [ "$web_host" != 0.0.0.0 ] || web_host=127.0.0.1
    [ "$core_host" != 0.0.0.0 ] || core_host=127.0.0.1
    for attempt in $(seq 1 30); do
        if systemctl is-active --quiet "$SERVICE" &&
            CONTROL_TOKEN="$MIHOMO_CONTROL_TOKEN" CLASH_SECRET="$MIHOMO_API_SECRET" \
            "$checked_release/node/bin/node" "$checked_release/launch/host-health.mjs" \
                "http://$web_host:$MIHOMO_API_PORT" "http://$core_host:$MIHOMO_CORE_API_PORT" "${health_args[@]}"; then
            return 0
        fi
        sleep 1
    done
    return 1
}
host_restore_service() {
    local failed=0
    if ! systemctl stop "$SERVICE"; then
        systemctl is-active --quiet "$SERVICE" && failed=1
    fi
    if (( unit_changed == 1 )); then
        # disable can also remove a linked unit. Restore the exact registration
        # AFTER removing the links introduced by this transaction.
        systemctl disable --runtime "$SERVICE" || failed=1
        systemctl disable "$SERVICE" || failed=1
    fi
    if [ -n "$previous" ]; then
        host_set_current "$previous" || failed=1
    else
        rm -f -- "$RUNTIME/current" || failed=1
    fi
    if (( previous_body == 1 )); then
        cp -a -- "$work/body.previous" "$UNIT_BODY.restore.$$" &&
            mv -Tf -- "$UNIT_BODY.restore.$$" "$UNIT_BODY" || failed=1
    else
        rm -f -- "$UNIT_BODY" || failed=1
    fi
    if (( previous_unit == 1 )); then
        cp -a -- "$work/unit.previous" "$UNIT.restore.$$" &&
            mv -Tf -- "$UNIT.restore.$$" "$UNIT" || failed=1
    else
        rm -f -- "$UNIT" || failed=1
    fi
    systemctl daemon-reload || failed=1
    if (( unit_changed == 1 )); then
        case "$previous_enabled" in
            enabled) systemctl enable "$SERVICE" || failed=1 ;;
            enabled-runtime) systemctl enable --runtime "$SERVICE" || failed=1 ;;
        esac
    fi
    if (( previous_active == 1 )); then
        if systemctl start "$SERVICE"; then
            host_wait_ready "$previous_release" || failed=1
        else
            failed=1
        fi
    fi
    return "$failed"
}
host_on_exit() {
    local rc=$? rollback_failed=0
    trap - EXIT
    if (( transaction_started == 1 && complete == 0 )); then
        echo "原生服务切换失败，正在恢复上一发布、unit 和启用/运行状态。" >&2
        if host_restore_service > "$RUNTIME/logs/last-rollback.log" 2>&1; then
            echo "已恢复原来的宿主机服务状态；回退记录：$RUNTIME/logs/last-rollback.log" >&2
        else
            rollback_failed=1
            echo "错误：回退未完全成功，服务可能仍不可用。请查看 $RUNTIME/logs/last-rollback.log；事务备份保留于 $work" >&2
        fi
        (( rc != 0 )) || rc=1
    fi
    rm -f -- "$RUNTIME/.current-next.$$" "$UNIT.next.$$" "$UNIT.restore.$$" "$UNIT_BODY.restore.$$"
    if (( rollback_failed == 0 )); then rm -rf -- "$work"; fi
    return "$rc"
}
host_main() {
    MODE="${1:-install}"
    case "$MODE" in install|update) ;; *) echo "Usage: host-install.sh [install|update]" >&2; return 2 ;; esac
    host_init_paths "$2"
    # shellcheck source=./common.sh
    source "$HERE/common.sh"
    # shellcheck source=./migrate.sh
    source "$HERE/migrate.sh"
    must_be_root
    umask 077
    host_assert_platform
    mkdir -p "$RUNTIME/releases" "$RUNTIME/systemd" "$RUNTIME/logs" "$RUNTIME/tmp"
    chmod 0700 "$RUNTIME" "$RUNTIME/systemd" "$RUNTIME/logs" "$RUNTIME/tmp"
    # Lock the registration directory itself, without creating another runtime
    # file outside MODULE. This also serializes competing installation roots.
    exec 8<"$(dirname -- "$UNIT")"
    flock -n 8 || die "另一个 Mihomo 原生安装正在操作 systemd 注册"
    exec 9>"$RUNTIME/install.lock"
    flock -n 9 || die "另一个 Mihomo 原生安装/更新仍在进行"
    host_assert_unit_owner
    if [ "$MODE" = update ] && [ ! -L "$RUNTIME/current" ]; then
        die "未发现宿主机安装；请先执行 sudo bash deploy.sh mihomo host"
    fi
    if [ -e "$RUNTIME/current" ] && [ ! -L "$RUNTIME/current" ]; then
        die "宿主机 current 路径不是符号链接，拒绝覆盖"
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if [ "$(docker inspect -f '{{.State.Running}}' mihomo 2>/dev/null || :)" = true ]; then
            die "现有 Docker mihomo 正在运行；请自行先停止：docker stop mihomo（脚本不会修改 Docker）"
        fi
    fi
    load_settings "$ROOT"
    MIHOMO_MIXED_PORT="${MIHOMO_MIXED_PORT:-7011}"
    MIHOMO_API_PORT="${MIHOMO_API_PORT:-7012}"
    MIHOMO_CORE_API_PORT="${MIHOMO_CORE_API_PORT:-7013}"
    MIHOMO_PROXY_BIND_IP="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
    MIHOMO_API_BIND_IP="${MIHOMO_API_BIND_IP:-0.0.0.0}"
    MIHOMO_CORE_API_BIND_IP="${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
    MIHOMO_PROXY_USER="${MIHOMO_PROXY_USER:-deploy}"
    local k
    for k in MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT; do
        check_port "$k" "${!k}"
        printf -v "$k" '%s' "$((10#${!k}))"
    done
    (( MIHOMO_MIXED_PORT != MIHOMO_API_PORT && MIHOMO_MIXED_PORT != MIHOMO_CORE_API_PORT &&
       MIHOMO_API_PORT != MIHOMO_CORE_API_PORT )) || die "Mihomo 三个监听端口不能冲突"
    for k in MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP; do check_ipv4 "$k" "${!k}"; done
    case "$MIHOMO_CORE_API_BIND_IP" in
        0.0.0.0|127.0.0.1) ;;
        *) die "宿主机模式的 MIHOMO_CORE_API_BIND_IP 仅支持 0.0.0.0 或 127.0.0.1（官方 Agent 需要本机健康检查）" ;;
    esac
    secret_when_blank MIHOMO_API_SECRET
    secret_when_blank MIHOMO_CONTROL_TOKEN
    work="$(mktemp -d "$RUNTIME/.host-build.XXXXXXXX")"
    transaction_started=0
    unit_changed=0
    complete=0
    trap host_on_exit EXIT
    host_snapshot_service
    host_seal_legacy_release
    mkdir -m 0700 "$work/tmp"
    export TMPDIR="$work/tmp"
    MIHOMO_HOST_RUNTIME="$RUNTIME" bash "$HERE/host-build.sh" "$work/release"
    local launch_file tag release
    mkdir -m 0700 "$work/release/launch"
    for launch_file in host-run.sh host-kernel.sh host-config.mjs common.sh host-health.mjs; do
        cp -- "$HERE/$launch_file" "$work/release/launch/$launch_file"
    done
    chmod 0700 "$work/release/launch/host-run.sh" "$work/release/launch/host-kernel.sh"
    [ -f "$work/release/server/index.mjs" ] && [ -f "$work/release/ui-dist/index.html" ] &&
        [ -x "$work/release/mihomo" ] && [ -x "$work/release/node/bin/node" ] ||
        die "候选原生发布不完整，旧服务未切换"
    tag="$(sed -n 's/^MetaCubeXD=//p' "$work/release/versions.txt")"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "候选发布版本信息不合法"
    initialize_aio "$MODULE/data" "$HERE/default-profile.yaml" "$MIHOMO_API_PORT"
    export MIHOMO_REAL_BIN="$work/release/mihomo"
    export MIHOMO_NODE_BIN="$work/release/node/bin/node"
    export MIHOMO_PROXY_BIND_IP MIHOMO_CORE_API_BIND_IP MIHOMO_MIXED_PORT MIHOMO_CORE_API_PORT
    export CLASH_SECRET="$MIHOMO_API_SECRET"
    export MIHOMO_KERNEL_TMPDIR="$work/kernel-tmp"
    bash "$work/release/launch/host-kernel.sh" -t -d "$MODULE/data/all-in-one" \
        -f "$MODULE/data/all-in-one/active.yaml" || die "宿主机内核未通过 Profile 验证；旧服务未切换"
    # Every deployment has its own wrapper snapshot, even when upstream's tag
    # is unchanged. Never overwrite files in an existing selected release.
    release="$(mktemp -d "$RUNTIME/releases/$tag.XXXXXXXX")"
    rmdir -- "$release"
    mv -- "$work/release" "$release"
    host_write_unit
    transaction_started=1
    if (( previous_active == 1 )); then systemctl stop "$SERVICE"; fi
    host_set_current "releases/${release##*/}"
    unit_changed=1
    mv -f -- "$work/unit.new" "$UNIT_BODY"
    # A real registration file is necessary for NAS volumes mounted later in
    # boot: systemd must read RequiresMountsFor before MODULE is accessible.
    # The generated original and every application artifact remain in MODULE.
    cp -- "$UNIT_BODY" "$UNIT.next.$$"
    chmod 0644 "$UNIT.next.$$"
    mv -Tf -- "$UNIT.next.$$" "$UNIT"
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
    systemctl start "$SERVICE" || die "无法启动宿主机 systemd 服务"
    host_wait_ready "$release" || die "宿主机 Web 或内核健康检查失败"
    complete=1
    echo "宿主机 Mihomo + 完整 Web/Agent 已启动。"
    echo "Web: http://<NAS-IP>:$MIHOMO_API_PORT/；Clash API: $MIHOMO_CORE_API_PORT；Proxy: $MIHOMO_PROXY_BIND_IP:$MIHOMO_MIXED_PORT"
    echo "运行、缓存、日志与 Profiles 根目录：$MODULE"
    echo "日志：$RUNTIME/logs/service.log；$RUNTIME/logs/service-error.log"
    echo "服务：systemctl status $SERVICE；官方 CONTROL_TOKEN 不是 Web 登录密码。"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    host_main "${1:-install}" "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi
