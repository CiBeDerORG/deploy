#!/usr/bin/env bash
# Manage opt-in access to the Mihomo proxy via an isolated Docker bridge network.
set -Eeuo pipefail

NETWORK=proxy-net
ACTION="${1:-}"
TARGET="${2:-}"

fail() { echo "代理网络错误：$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "请使用 sudo 执行。"
command -v docker >/dev/null 2>&1 || fail "未安装 Docker。"
docker info >/dev/null 2>&1 || fail "Docker daemon 不可用。"

network_exists() { docker network inspect "$NETWORK" >/dev/null 2>&1; }

ensure_network() {
    local driver internal scope
    if network_exists; then
        driver="$(docker network inspect -f '{{.Driver}}' "$NETWORK")"
        internal="$(docker network inspect -f '{{.Internal}}' "$NETWORK")"
        scope="$(docker network inspect -f '{{.Scope}}' "$NETWORK")"
        [ "$driver" = bridge ] && [ "$internal" = true ] && [ "$scope" = local ] ||
            fail "已有 $NETWORK 不是本机 internal bridge 网络（driver=$driver, internal=$internal, scope=$scope）；拒绝接管已有网络，请人工检查。"
    else
        docker network create --driver bridge --internal \
            --label org.cibeder.deploy.role=mihomo-proxy "$NETWORK" >/dev/null ||
            fail "创建 $NETWORK 失败"
        echo "已创建 Docker 内部共享网络：$NETWORK"
    fi
}

container_id() {
    docker container inspect -f '{{.Id}}' "$1" 2>/dev/null ||
        fail "找不到容器：$1（请填写 docker ps 中的容器名称或 ID）"
}

is_connected() {
    local id="$1"
    docker network inspect -f '{{range $id, $_ := .Containers}}{{println $id}}{{end}}' "$NETWORK" |
        grep -Fxq -- "$id"
}

require_mihomo() {
    local id state
    id="$(container_id mihomo)"
    state="$(docker container inspect -f '{{.State.Status}}' mihomo)"
    [ "$state" = running ] || fail "Mihomo 未运行：$state；请先安装/启动 Mihomo。"
    network_exists || fail "$NETWORK 不存在；请先执行 sudo bash deploy.sh mihomo update。"
    is_connected "$id" || fail "Mihomo 尚未加入 $NETWORK；请先执行 sudo bash deploy.sh mihomo update。"
}

target_id() {
    [ -n "$TARGET" ] || fail "缺少容器名，例如：sudo bash deploy.sh proxy $ACTION sub2api"
    local id
    id="$(container_id "$TARGET")"
    [ "$id" != "$(container_id mihomo)" ] ||
        fail "Mihomo 网络由 Compose 管理，不允许通过快捷命令断开/调整。"
    printf '%s\n' "$id"
}

case "$ACTION" in
    ensure)
        [ "$#" -eq 1 ] || fail "ensure 不接受容器参数。"
        ensure_network
        ;;
    connect)
        [ "$#" -eq 2 ] || fail "用法：sudo bash deploy.sh proxy connect <容器名>"
        require_mihomo
        id="$(target_id)"
        if is_connected "$id"; then
            echo "$TARGET 已连接 $NETWORK，无需重复操作。"
            exit 0
        fi
        mode="$(docker container inspect -f '{{.HostConfig.NetworkMode}}' "$id")"
        case "$mode" in host|none|container:*) fail "$TARGET 使用 $mode 网络模式，不支持动态接入共享网络。" ;; esac
        docker network connect "$NETWORK" "$id"
        echo "已接入：$TARGET -> $NETWORK；容器内通过 mihomo:7890 使用代理（需代理认证和应用侧配置）。"
        ;;
    disconnect)
        [ "$#" -eq 2 ] || fail "用法：sudo bash deploy.sh proxy disconnect <容器名>"
        require_mihomo
        id="$(target_id)"
        if ! is_connected "$id"; then
            echo "$TARGET 未连接 $NETWORK，无需断开。"
            exit 0
        fi
        docker network disconnect "$NETWORK" "$id"
        echo "已断开：$TARGET -/-> $NETWORK（不删除容器，不调整其他网络）。"
        ;;
    status)
        [ "$#" -le 2 ] || fail "用法：sudo bash deploy.sh proxy status [容器名]"
        require_mihomo
        if [ -n "$TARGET" ]; then
            id="$(target_id)"
            if is_connected "$id"; then echo "$TARGET：已接入 $NETWORK"; else echo "$TARGET：未接入 $NETWORK"; fi
        else
            echo "$NETWORK 中的容器："
            docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$NETWORK"
        fi
        ;;
    *)
        fail "用法：sudo bash deploy.sh proxy {connect|disconnect|status} [容器名]"
        ;;
esac
