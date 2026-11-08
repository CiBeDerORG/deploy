#!/usr/bin/env bash
# Build a complete candidate without touching current, systemd or live data.
# All downloads, caches and temporary files stay within MODULE/runtime/host.
set -Eeuo pipefail
[ "$#" -eq 1 ] && [[ "$1" = /* ]] || { echo "Usage: host-build.sh ABSOLUTE_STAGING_RELEASE" >&2; exit 2; }
: "${MIHOMO_HOST_RUNTIME:?Missing module-local runtime directory}"
RUNTIME="$(cd -- "$MIHOMO_HOST_RUNTIME" && pwd -P)"
DEST="$1"
work="$(dirname -- "$DEST")/builder"
[[ "$DEST" = "$RUNTIME"/*/* ]] || { echo "Candidate must be staged under runtime" >&2; exit 2; }
[ ! -e "$DEST" ] && [ ! -e "$work" ] || { echo "Candidate/build directory already exists" >&2; exit 1; }
umask 077
mkdir -p "$DEST" "$work/tmp" "$RUNTIME/cache" "$RUNTIME/build-config"
export TMPDIR="$work/tmp"
export COREPACK_HOME="$RUNTIME/cache/corepack"
export PNPM_HOME="$RUNTIME/cache/pnpm-home"
export XDG_CACHE_HOME="$RUNTIME/cache/xdg"
export XDG_DATA_HOME="$RUNTIME/cache/xdg-data"
export XDG_CONFIG_HOME="$RUNTIME/build-config/xdg"
export npm_config_cache="$RUNTIME/cache/npm"
export npm_config_userconfig="$RUNTIME/build-config/npmrc"
export npm_config_globalconfig="$RUNTIME/build-config/npmrc-global"
export npm_config_store_dir="$RUNTIME/cache/pnpm-store"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 HUSKY=0
# Nuxt's optional telemetry otherwise writes ~/.nuxtrc (outside MODULE).
export NUXT_TELEMETRY_DISABLED=1
# Node 22.23 supports standard HTTP(S)_PROXY for its own fetch clients too.
# Keep an explicitly chosen value; never alter the user's proxy endpoints.
export NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"
[ -e "$npm_config_userconfig" ] || : > "$npm_config_userconfig"
[ -e "$npm_config_globalconfig" ] || : > "$npm_config_globalconfig"
case "$(uname -m)" in
    x86_64) node_arch=linux-x64; kernel_arch=amd64-compatible ;;
    aarch64|arm64) node_arch=linux-arm64; kernel_arch=arm64 ;;
    *) echo "原生模式仅支持 amd64 / arm64" >&2; exit 1 ;;
esac
SOFTWARE_ROOT="$(cd -- "$RUNTIME/../../.." && pwd -P)"
source "$SOFTWARE_ROOT/deploy/lib/versions.sh"
deploy_load_versions "$SOFTWARE_ROOT" || exit 1
NODE_VERSION="$MIHOMO_NODE_VERSION"
NODE_DIR="node-$NODE_VERSION-$node_arch"
node="$RUNTIME/$NODE_DIR/bin/node"
if [ ! -x "$node" ]; then
    [ ! -e "$RUNTIME/$NODE_DIR" ] || { echo "Node runtime目录不完整，拒绝覆盖" >&2; exit 1; }
    archive="$NODE_DIR.tar.xz"
    node_url="https://nodejs.org/dist/$NODE_VERSION"
    curl -fSL --retry 3 "$node_url/$archive" -o "$work/$archive"
    curl -fSL --retry 3 "$node_url/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
    awk -v name="$archive" '$2 == name {print}' "$work/SHASUMS256.txt" > "$work/node-sha256"
    [ -s "$work/node-sha256" ] || { echo "官方Node校验清单缺少目标架构" >&2; exit 1; }
    (cd "$work" && sha256sum -c node-sha256)
    mkdir "$work/node"
    tar -xJf "$work/$archive" --strip-components=1 -C "$work/node"
    "$work/node/bin/node" -v >/dev/null
    mv -- "$work/node" "$RUNTIME/$NODE_DIR"
fi
"$node" -v >/dev/null
export PATH="$RUNTIME/$NODE_DIR/bin:$PATH"
# The public release redirect avoids the shared anonymous GitHub API quota.
# Accept only a canonical release URL from the official repository.
if [ "$MIHOMO_METACUBEXD_VERSION" = latest ]; then
    release_url="$(curl -fsSLI --retry 3 --output /dev/null --write-out '%{url_effective}' https://github.com/MetaCubeX/metacubexd/releases/latest)"
    [[ "$release_url" =~ ^https://github\.com/MetaCubeX/metacubexd/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || {
        echo "无法识别官方最新发布地址" >&2; exit 1;
    }
    tag="${BASH_REMATCH[1]}"
else
    tag="$MIHOMO_METACUBEXD_VERSION"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "无法识别官方发布版本" >&2; exit 1; }
echo "构建官方 MetaCubeXD $tag（server 与 UI 产物隔离）..."
git clone --depth 1 --branch "$tag" https://github.com/MetaCubeX/metacubexd.git "$work/source"
source_dir="$work/source"
if [ "$MIHOMO_KERNEL_VERSION" = upstream ]; then
    version="$(sed -nE 's/^ARG MIHOMO_VERSION=(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$source_dir/apps/server/Dockerfile" | head -n 1)"
else
    version="$MIHOMO_KERNEL_VERSION"
fi
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "无效的 Mihomo 内核版本" >&2; exit 1; }
corepack enable pnpm --install-directory "$RUNTIME/$NODE_DIR/bin"
(
    cd "$source_dir"
    corepack pnpm install --frozen-lockfile --store-dir "$RUNTIME/cache/pnpm-store"
    # Match the upstream Docker server stage: UI output MUST NOT exist here.
    [ ! -e packages/ui/.output/public ] || { echo "UI构建产物污染server阶段" >&2; exit 1; }
    corepack pnpm --filter @metacubexd/server... build
    [ ! -e apps/server/.output/public/config.js ] || { echo "静态config.js将遮挡动态认证路由" >&2; exit 1; }
    cp -a apps/server/.output/. "$DEST/"
    corepack pnpm --filter @metacubexd/ui generate
    cp -a packages/ui/.output/public "$DEST/ui-dist"
)
# Ship the exact upstream lockfile-resolved YAML package for the native adapter.
yaml_dir="$("$node" -e 'const p=require("node:path"),f=require("node:fs");process.stdout.write(p.dirname(f.realpathSync(require.resolve("yaml/package.json",{paths:[process.argv[1]]}))))' "$source_dir/packages/agent")"
mkdir -p "$DEST/node_modules"
cp -aL "$yaml_dir" "$DEST/node_modules/yaml"
asset="mihomo-linux-$kernel_arch-$version.gz"
curl -fSL --retry 3 "https://github.com/MetaCubeX/mihomo/releases/download/$version/$asset" -o "$work/$asset"
gzip -t "$work/$asset"
gzip -dc "$work/$asset" > "$DEST/mihomo"
chmod 0755 "$DEST/mihomo"
"$DEST/mihomo" -v
[ -f "$DEST/server/index.mjs" ] && [ -f "$DEST/ui-dist/index.html" ] || { echo "构建产物不完整" >&2; exit 1; }
# Both staging ($RUNTIME/.host-build.ID/release) and final releases live two
# levels below RUNTIME, so this pin remains valid across the atomic move.
ln -s "../../$NODE_DIR" "$DEST/node"
printf 'MetaCubeXD=%s\nMihomo=%s\nNode=%s\n' "$tag" "$version" "$NODE_VERSION" > "$DEST/versions.txt"
echo "候选版本构建完成，尚未切换运行服务。"
