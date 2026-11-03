#!/usr/bin/env bash
# GitHub Release 下载轮换、失败切换、校验和官方回退的无网络回归测试。
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo/lib/release-sources.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/software/deploy" "$tmp/bin" "$tmp/dist" "$tmp/fixture"
asset=easyhostagent-linux-amd64
base=https://github.com/CiBeDerORG/EasyHostAgent/releases/download/v0.1.0-appstore.dev
envfile="$tmp/software/deploy/.env"
printf 'mock-binary\n' > "$tmp/fixture/$asset"
(cd "$tmp/fixture" && sha256sum "$asset" > "$asset.sha256")
cat > "$envfile" <<'EOF'
GITHUB_RELEASE_SOURCE=mirror
GITHUB_RELEASE_MIRRORS=ghproxy,ghfast,ghproxy-net
EOF
export MOCK_ROOT="$tmp"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dst='' url=''
while (( $# > 0 )); do
    case "$1" in
        -o|--output) dst="$2"; shift 2 ;;
        --connect-timeout|--max-time|--proto|--proto-redir) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >> "$MOCK_ROOT/requests"
case "$url" in
    https://gh-proxy.org/*)
        case "$url" in *.sha256) cp "$MOCK_ROOT/fixture/easyhostagent-linux-amd64.sha256" "$dst" ;;
            *) printf 'corrupt' > "$dst" ;; esac ;;
    https://ghfast.top/*|https://ghproxy.net/*|https://github.com/*)
        cp "$MOCK_ROOT/fixture/${url##*/}" "$dst" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"

# 首轮 GH-Proxy 二进制校验失败后必须切换 GHFast。
deploy_download_github_release_pair "$tmp/software" "$envfile" "$base" "$asset" "$tmp/dist"
grep -q 'gh-proxy.org/' "$tmp/requests"
grep -q 'ghfast.top/' "$tmp/requests"
[[ "$(cat "$tmp/dist/$asset")" == mock-binary ]]
[[ "$(cat "$tmp/software/deploy/state/github-release-mirror.last")" == ghproxy ]]

# 次轮自动轮换到 GHFast，第三轮轮换到 GHProxy.net。
: > "$tmp/requests"
deploy_download_github_release_pair "$tmp/software" "$envfile" "$base" "$asset" "$tmp/dist"
grep -q 'ghfast.top/' "$tmp/requests"
! grep -q 'gh-proxy.org/' "$tmp/requests"
: > "$tmp/requests"
deploy_download_github_release_pair "$tmp/software" "$envfile" "$base" "$asset" "$tmp/dist"
grep -q 'ghproxy.net/' "$tmp/requests"
[[ "$(cat "$tmp/software/deploy/state/github-release-mirror.last")" == ghproxy-net ]]

# 官方直连不轮换；拒绝未知代理站并防止下载失败覆盖现有文件。
printf 'GITHUB_RELEASE_SOURCE=original\n' > "$envfile"
: > "$tmp/requests"
deploy_download_github_release_pair "$tmp/software" "$envfile" "$base" "$asset" "$tmp/dist"
grep -q '^https://github.com/' "$tmp/requests"
printf 'GITHUB_RELEASE_SOURCE=mirror\nGITHUB_RELEASE_MIRRORS=invalid-mirror\n' > "$envfile"
: > "$tmp/requests"
if deploy_download_github_release_pair "$tmp/software" "$envfile" "$base" "$asset" "$tmp/dist" > "$tmp/failed" 2>&1; then
    echo '未知代理站不应通过校验' >&2; exit 1
fi
[[ ! -s "$tmp/requests" ]]
printf 'GITHUB_RELEASE_SOURCE=mirror\nGITHUB_RELEASE_MIRRORS=ghproxy\n' > "$envfile"
rm -f "$tmp/fixture/$asset" "$tmp/fixture/$asset.sha256"
if deploy_download_github_release_pair "$tmp/software" "$envfile" "$base" "$asset" "$tmp/dist" > "$tmp/failed" 2>&1; then
    echo '全部下载失败不应成功' >&2; exit 1
fi
[[ "$(cat "$tmp/dist/$asset")" == mock-binary ]]
grep -q '全部加速站及 GitHub 官方下载均失败' "$tmp/failed"
echo 'Release 加速轮换、校验、失败切换、官方回退及文件保留测试通过'
