#!/usr/bin/env bash
# 在独立的软件根目录验证共享库作为一组发布，不调用真实服务。
set -Eeuo pipefail
(( EUID == 0 )) || { echo "请用 sudo 运行共享库权限测试" >&2; exit 1; }
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
export SOFTWARE_ROOT="$temp/software"
source "$repo/deploy.sh" help >/dev/null
ROOT_DIR="$temp/source"
mkdir -p "$ROOT_DIR" "$GLOBAL_ENV_DIR/lib"
cp -a "$repo/lib" "$ROOT_DIR/lib"
modules=(image-sources.sh release-sources.sh source-migration.sh app-config.sh platform.sh versions.sh versions.env)

# 预装旧版本，并保留一个共享目录下的本地文件。
for module in "${modules[@]}"; do printf '旧版 %s\n' "$module" > "$GLOBAL_ENV_DIR/lib/$module"; done
printf '保留\n' > "$GLOBAL_ENV_DIR/lib/local.txt"
cp -a "$GLOBAL_ENV_DIR/lib" "$temp/before"
mv "$ROOT_DIR/lib/versions.env" "$temp/versions.env"
if sync_shared_libraries > "$temp/output" 2>&1; then echo "缺少版本文件却报告同步成功" >&2; exit 1; fi
diff -r "$temp/before" "$GLOBAL_ENV_DIR/lib"
mv "$temp/versions.env" "$ROOT_DIR/lib/versions.env"

# platform.sh 是这次新装的文件。末项发布失败时，它和已替换的旧文件都必须恢复。
rm -- "$GLOBAL_ENV_DIR/lib/platform.sh" "$temp/before/platform.sh"
(
    run_root() {
        if [[ "$1" == mv && "${!#}" == "$GLOBAL_ENV_DIR/lib/versions.env" && ! -e "$temp/failed" ]]; then
            touch "$temp/failed"
            return 47
        fi
        "$@"
    }
    if sync_shared_libraries > "$temp/output" 2>&1; then exit 1; fi
    [[ -e "$temp/failed" ]]
)
diff -r "$temp/before" "$GLOBAL_ENV_DIR/lib"
sync_shared_libraries
for module in "${modules[@]}"; do
    cmp "$ROOT_DIR/lib/$module" "$GLOBAL_ENV_DIR/lib/$module"
    [[ "$(stat -c %u:%g:%a "$GLOBAL_ENV_DIR/lib/$module")" == 0:0:644 ]]
done
cmp "$temp/before/local.txt" "$GLOBAL_ENV_DIR/lib/local.txt"

# 仓库就在软件根目录下时，同一份文件保持原 inode 并修正权限。
GLOBAL_ENV_DIR="$ROOT_DIR"
chmod 0600 "$ROOT_DIR/lib/platform.sh"
inode="$(stat -c %i "$ROOT_DIR/lib/platform.sh")"
sync_shared_libraries
[[ "$(stat -c %i:%a "$ROOT_DIR/lib/platform.sh")" == "$inode:644" ]]

# 从仓库外的空软件目录安装，正式脚本应能加载平台模块并走到镜像拉取。
export SOFTWARE_ROOT="$temp/clean-install" PATH="$temp/bin:$PATH" TEST_PULL_LOG="$temp/pulls"
mkdir -p "$temp/bin"
cat > "$temp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == compose ]] || exit 1
case "${!#}" in version|config) exit 0 ;; esac
[[ "${*: -2:1}" == pull ]] || exit 1
echo "${!#}" >> "$TEST_PULL_LOG"
exit 78
MOCK
chmod +x "$temp/bin/docker"
bash "$repo/deploy.sh" env > "$temp/output"
mkdir -p "$SOFTWARE_ROOT/portainer/config" "$SOFTWARE_ROOT/easytier/config"
(umask 077
    printf 'PORTAINER_ADMIN_PASSWORD=test-only-password\n' > "$SOFTWARE_ROOT/portainer/config/.secrets"
    printf 'EASYTIER_WEB_API_HOST=http://127.0.0.1:7007\n' > "$SOFTWARE_ROOT/easytier/config/.env"
)
for app in portainer easytier; do
    if bash "$repo/deploy.sh" "$app" install > "$temp/output" 2>&1; then exit 1; else status=$?; fi
    [[ "$status" == 78 ]] || { echo "$app 安装未到达测试拉取入口，退出码 $status" >&2; exit 1; }
    grep -Fxq "$app" "$TEST_PULL_LOG"
done
echo "共享库完整性、回滚、独立安装和原位同步验证通过"
