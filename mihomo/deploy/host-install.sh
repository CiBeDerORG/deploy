#!/usr/bin/env bash
# Native Linux installer for the SAME official MetaCubeXD UI + Agent + mihomo.
# No Docker runtime or host package installation: build a released upstream tag
# under mihomo/runtime/host; reuse the Docker profile store under data/all-in-one.
set -Eeuo pipefail
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "Usage: host-install.sh [install|update]" >&2; exit 2 ;; esac
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
ROOT="$(cd -- "$MODULE/.." && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"
# shellcheck source=./migrate.sh
source "$HERE/migrate.sh"
must_be_root
[ "$(uname -s)" = Linux ] || die "原生模式仅支持 Linux"
for cmd in systemctl git curl tar xz sha256sum awk gzip flock; do
    command -v "$cmd" >/dev/null 2>&1 || die "原生安装缺少 $cmd"
done
[ -d /run/systemd/system ] || die "原生模式需要 systemd 作为 PID 1"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if [ "$(docker inspect -f '{{.State.Running}}' mihomo 2>/dev/null || :)" = true ]; then
        die "现有 Docker mihomo 正在运行；共享同一数据目录和端口。请自行先停止：docker stop mihomo（脚本不会修改 Docker）"
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
for k in MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT; do check_port "$k" "${!k}"; done
(( 10#$MIHOMO_MIXED_PORT != 10#$MIHOMO_API_PORT &&
   10#$MIHOMO_MIXED_PORT != 10#$MIHOMO_CORE_API_PORT &&
   10#$MIHOMO_API_PORT != 10#$MIHOMO_CORE_API_PORT )) || die "Mihomo 三个监听端口不能冲突"
for k in MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP; do check_ipv4 "$k" "${!k}"; done
# Official Agent polls its core on 127.0.0.1 if the configured controller is
# 0.0.0.0. A single non-loopback address would break that upstream health check.
case "$MIHOMO_CORE_API_BIND_IP" in
    0.0.0.0|127.0.0.1) ;;
    *) die "宿主机模式的 MIHOMO_CORE_API_BIND_IP 仅支持 0.0.0.0 或 127.0.0.1（官方 Agent 需要本机健康检查）" ;;
esac
secret_when_blank MIHOMO_API_SECRET
secret_when_blank MIHOMO_CONTROL_TOKEN

RUNTIME="$MODULE/runtime/host"
UNIT=/etc/systemd/system/deploy-mihomo.service
SERVICE=deploy-mihomo.service
mkdir -p "$RUNTIME/releases"
chmod 0700 "$RUNTIME"
exec 9>"$RUNTIME/install.lock"
flock -n 9 || die "另一个 Mihomo 原生安装/更新仍在进行"
if [ -e "$UNIT" ] && ! grep -Fq '# Managed by CiBeDerORG/deploy Mihomo native installer' "$UNIT"; then
    die "同名 systemd 服务已存在且非本仓库管理，拒绝覆盖：$UNIT"
fi
if [ "$MODE" = update ] && [ ! -L "$RUNTIME/current" ]; then
    die "未发现宿主机安装；请先执行 sudo bash deploy.sh mihomo host"
fi
if [ -e "$RUNTIME/current" ] && [ ! -L "$RUNTIME/current" ]; then
    die "宿主机 current 路径不是符号链接，拒绝覆盖"
fi

work="$(mktemp -d "$RUNTIME/.host-build.XXXXXXXX")"
previous=""
previous_active=0
switched=0
complete=0
if [ -L "$RUNTIME/current" ]; then previous="$(readlink "$RUNTIME/current")"; fi
if systemctl is-active --quiet "$SERVICE"; then previous_active=1; fi
set_current() {
    local target="$1"
    ln -s "$target" "$RUNTIME/.current-next.$$"
    mv -Tf "$RUNTIME/.current-next.$$" "$RUNTIME/current"
}
on_exit() {
    local rc=$?
    trap - EXIT
    if (( switched == 1 && complete == 0 )); then
        echo "原生服务启动失败，恢复原来的宿主机版本指针（不会触碰 Docker）。" >&2
        systemctl stop "$SERVICE" >/dev/null 2>&1 || :
        if [ -n "$previous" ]; then
            set_current "$previous" || :
            if (( previous_active == 1 )); then
                systemctl start "$SERVICE" >/dev/null 2>&1 || :
            fi
        else
            rm -f -- "$RUNTIME/current"
            systemctl disable "$SERVICE" >/dev/null 2>&1 || :
        fi
    fi
    rm -rf -- "$work"
    return "$rc"
}
trap on_exit EXIT

arch="$(uname -m)"
case "$arch" in
    x86_64) node_arch=linux-x64; kernel_arch=amd64-compatible ;;
    aarch64|arm64) node_arch=linux-arm64; kernel_arch=arm64 ;;
    *) die "暂不支持 CPU 架构：$arch（仅 amd64 / arm64）" ;;
esac

# Use a verified official Node 22 binary privately, not apt and not the NAS
# system node. The version matches the official server's Node 22 Dockerfile.
NODE_VERSION=v22.23.4
NODE_DIR="node-$NODE_VERSION-$node_arch"
node_path="$RUNTIME/$NODE_DIR/bin/node"
if [ ! -x "$node_path" ]; then
    archive="$NODE_DIR.tar.xz"
    node_url="https://nodejs.org/dist/$NODE_VERSION"
    echo "下载独立 Node.js $NODE_VERSION ($node_arch) 并核对官方 SHA256..."
    curl -fSL --retry 3 "$node_url/$archive" -o "$work/$archive"
    curl -fSL --retry 3 "$node_url/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
    grep -F "  $archive" "$work/SHASUMS256.txt" > "$work/node-sha256"
    [ -s "$work/node-sha256" ] || die "Node.js 官方 SHA256 清单缺少 $archive"
    (cd "$work" && sha256sum -c node-sha256) || die "Node.js 下载校验失败"
    mkdir -p "$work/node"
    tar -xJf "$work/$archive" --strip-components=1 -C "$work/node"
    "$work/node/bin/node" -v >/dev/null || die "Node.js 架构/运行库不兼容"
    mv -- "$work/node" "$RUNTIME/$NODE_DIR"
fi
[ -x "$node_path" ] || die "Node.js runtime missing"

# Always use an official release, rather than building a moving main branch.
tag="$(curl -fSL --retry 3 https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest |
    sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' | head -n 1)"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法获取 MetaCubeXD 官方最新发布版本"
release="$RUNTIME/releases/$tag"
if [ ! -f "$release/server/index.mjs" ] || [ ! -f "$release/ui-dist/index.html" ] || [ ! -x "$release/mihomo" ]; then
    [ ! -e "$release" ] || die "已存在不完整的发布目录：$release；请人工检查，不覆盖"
    echo "从官方发布版本 $tag 构建完整 Web / Agent / Mihomo（不使用 Docker）..."
    git clone --depth 1 --branch "$tag" https://github.com/MetaCubeX/metacubexd.git "$work/source"
    version="$(sed -nE 's/^ARG MIHOMO_VERSION=(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$work/source/apps/server/Dockerfile" | head -n 1)"
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "上游 Dockerfile 未声明可识别的内核版本"
    export PATH="$RUNTIME/$NODE_DIR/bin:$PATH"
    export COREPACK_HOME="$RUNTIME/corepack-cache"
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    export HUSKY=0
    # The monorepo's own build scripts invoke plain "pnpm"; enable the shim
    # inside our isolated Node distribution, never in the system-wide PATH.
    corepack enable pnpm --install-directory "$RUNTIME/$NODE_DIR/bin" ||
        die "无法在隔离 Node 环境中启用 pnpm"
    (cd "$work/source" &&
       corepack pnpm install --frozen-lockfile &&
       corepack pnpm build) || die "MetaCubeXD 上游构建失败；旧服务及数据未切换"
    mkdir -p "$work/release"
    cp -a "$work/source/apps/server/.output/server" "$work/release/server"
    cp -a "$work/source/packages/ui/.output/public" "$work/release/ui-dist"
    asset="mihomo-linux-$kernel_arch-$version.gz"
    curl -fSL --retry 3 \
        "https://github.com/MetaCubeX/mihomo/releases/download/$version/$asset" \
        -o "$work/$asset"
    gzip -t "$work/$asset" || die "Mihomo 内核压缩包已损坏"
    gzip -dc "$work/$asset" > "$work/release/mihomo"
    chmod 0755 "$work/release/mihomo"
    "$work/release/mihomo" -v || die "Mihomo 内核无法在当前宿主机运行"
    [ -f "$work/release/server/index.mjs" ] &&
    [ -f "$work/release/ui-dist/index.html" ] || die "MetaCubeXD Web/Agent 构建产物不完整"
    printf 'MetaCubeXD=%s\nMihomo=%s\nNode=%s\n' "$tag" "$version" "$NODE_VERSION" > "$work/release/versions.txt"
    mv -- "$work/release" "$release"
fi

# Never rewrite already-managed subscription URLs, profiles, authentication,
# selection state or active.yaml. This is the exact Docker data root.
initialize_aio "$MODULE/data" "$HERE/default-profile.yaml" "$MIHOMO_API_PORT"
export MIHOMO_REAL_BIN="$release/mihomo"
export MIHOMO_PROXY_BIND_IP MIHOMO_CORE_API_BIND_IP
export MIHOMO_MIXED_PORT MIHOMO_CORE_API_PORT
export MIHOMO_KERNEL_TMPDIR="$work/kernel-tmp"
mkdir -p "$MIHOMO_KERNEL_TMPDIR"
bash "$HERE/host-kernel.sh" -t -d "$MODULE/data/all-in-one" \
    -f "$MODULE/data/all-in-one/active.yaml" || die "宿主机内核未通过 Profile 验证；Docker 数据未覆盖"

# This service uses the mirrored deploy files but keeps runtime and data outside
# the mirror so that deploy.sh sync/update never removes them.
cat > "$UNIT" <<EOF_UNIT
# Managed by CiBeDerORG/deploy Mihomo native installer
[Unit]
Description=Deploy Mihomo + MetaCubeXD full native Web/Agent
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash "$HERE/host-run.sh"
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=30
RuntimeDirectory=deploy-mihomo
RuntimeDirectoryMode=0700
UMask=0077
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF_UNIT
chmod 0644 "$UNIT"
# Stage complete: from this point a failure switches the previous native
# release back. Docker containers, images, Compose and proxy-net are untouched.
set_current "releases/$tag"
switched=1
ln -s "$NODE_DIR" "$RUNTIME/.node-next.$$"
mv -Tf "$RUNTIME/.node-next.$$" "$RUNTIME/node-current"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE" || die "无法启动宿主机 systemd 服务"
web_host="$MIHOMO_API_BIND_IP"
core_host="$MIHOMO_CORE_API_BIND_IP"
[ "$web_host" != 0.0.0.0 ] || web_host=127.0.0.1
[ "$core_host" != 0.0.0.0 ] || core_host=127.0.0.1
for attempt in $(seq 1 30); do
    if curl -fsS --max-time 2 -o /dev/null "http://$web_host:$MIHOMO_API_PORT/api/control/health" &&
       curl -fsS --max-time 2 -o /dev/null -H "Authorization: Bearer $MIHOMO_API_SECRET" \
            "http://$core_host:$MIHOMO_CORE_API_PORT/version"; then
        complete=1
        echo "宿主机 Mihomo + 完整 Web/Agent 已启动。"
        echo "Web: http://<NAS-IP>:$MIHOMO_API_PORT/；Clash API: $MIHOMO_CORE_API_PORT；Proxy: $MIHOMO_PROXY_BIND_IP:$MIHOMO_MIXED_PORT"
        echo "Profiles 与 Docker 共用：$MODULE/data/all-in-one"
        echo "服务：systemctl status $SERVICE；日志：journalctl -u $SERVICE -f"
        echo "注意：仅能由一个安装方式运行。官方 CONTROL_TOKEN 不是 Web 登录密码。"
        exit 0
    fi
    sleep 1
done
die "宿主机 Web 或内核健康检查失败；journalctl -u $SERVICE -n 100"
