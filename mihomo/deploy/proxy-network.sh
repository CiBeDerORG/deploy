#!/usr/bin/env bash
# Dedicated opt-in Docker network for the official bundled Mihomo kernel.
set -Eeuo pipefail
NET=proxy-net
action="${1:-}" target="${2:-}"
err() { printf 'proxy-net：%s\n' "$*" >&2; exit 1; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
PLATFORM_LIB="$SOFTWARE_ROOT/deploy/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || PLATFORM_LIB="$SOFTWARE_ROOT/lib/platform.sh"
[ -f "$PLATFORM_LIB" ] || err "缺少跨平台 Deploy 辅助脚本"
# shellcheck source=../../lib/platform.sh
source "$PLATFORM_LIB"
deploy_require_root || err "请使用 sudo"
command -v docker >/dev/null 2>&1 || err "Docker 未安装"
docker info >/dev/null 2>&1 || err "Docker daemon 不可用"

has_net() { docker network inspect "$NET" >/dev/null 2>&1; }
ensure_net() {
    if has_net; then
        [ "$(docker network inspect -f '{{.Driver}}' "$NET")" = bridge ] &&
        [ "$(docker network inspect -f '{{.Internal}}' "$NET")" = true ] &&
        [ "$(docker network inspect -f '{{.Scope}}' "$NET")" = local ] ||
            err "已有同名网络不是 local internal bridge，拒绝接管"
    else
        docker network create --driver bridge --internal \
            --label org.cibeder.deploy.role=mihomo-proxy "$NET" >/dev/null ||
            err "无法创建 $NET"
        echo "已创建 $NET"
    fi
}
cid() { docker container inspect -f '{{.Id}}' "$1" 2>/dev/null || err "找不到容器：$1"; }
joined() {
    docker network inspect -f '{{range $key, $_ := .Containers}}{{println $key}}{{end}}' "$NET" |
        grep -Fxq "$1"
}
ready() {
    has_net || err "$NET 不存在，先安装 Mihomo"
    local mid
    mid="$(cid mihomo)"
    [ "$(docker inspect -f '{{.State.Status}}' "$mid")" = running ] || err "Mihomo 容器未运行"
    joined "$mid" || err "Mihomo 尚未接入 $NET"
}
target_id() {
    [ -n "$target" ] || err "请提供目标容器名称"
    local id
    id="$(cid "$target")"
    [ "$id" != "$(cid mihomo)" ] || err "禁止修改 Mihomo 自身的 Compose 网络连接"
    printf '%s\n' "$id"
}
case "$action" in
    ensure)
        [ "$#" -eq 1 ] || err "用法：proxy ensure"
        ensure_net ;;
    connect)
        [ "$#" -eq 2 ] || err "用法：proxy connect <容器名>"
        ready
        id="$(target_id)"
        if joined "$id"; then echo "$target 已接入 $NET"; exit 0; fi
        mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$id")"
        case "$mode" in host|none|container:*) err "$target 的 $mode 模式不支持动态接入" ;; esac
        docker network connect "$NET" "$id"
        echo "$target 已接入；应用需自行配置有认证的 mihomo:7890" ;;
    disconnect)
        [ "$#" -eq 2 ] || err "用法：proxy disconnect <容器名>"
        ready
        id="$(target_id)"
        if joined "$id"; then docker network disconnect "$NET" "$id"; fi
        echo "$target 已断开或此前未连接 $NET" ;;
    status)
        [ "$#" -le 2 ] || err "用法：proxy status [容器名]"
        ready
        if [ -n "$target" ]; then
            id="$(target_id)"
            if joined "$id"; then echo "$target：已接入 $NET"; else echo "$target：未接入 $NET"; fi
        else
            docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$NET"
        fi ;;
    *) err "用法：proxy {ensure|connect|disconnect|status} [容器名]" ;;
esac
