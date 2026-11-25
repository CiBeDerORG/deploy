#!/usr/bin/env bash
# 使用临时软件根目录验证实际 sync/update 调用链；替身只注入文件操作故障，不启动容器。
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
export SOFTWARE_ROOT="$temp/installed"
source "$repo/deploy.sh" help >/dev/null
ROOT_DIR="$temp/source"
app=demo
source_dir="$ROOT_DIR/$app"
target_dir="$SOFTWARE_ROOT/$app"
export lifecycle_log="$temp/lifecycle.log"
mkdir -p "$source_dir/deploy" "$source_dir/config" "$source_dir/data" "$target_dir/deploy" "$target_dir/data" "$temp/archives"
printf '%s\n' 'echo new >> "$lifecycle_log"' > "$source_dir/deploy/update.sh"
printf '%s\n' 'echo old >> "$lifecycle_log"' > "$target_dir/deploy/update.sh"
printf '%s\n' '用户数据' > "$target_dir/data/value"
printf '%s\n' '模板数据' > "$source_dir/data/value"
printf '%s\n' '用户配置' > "$target_dir/deploy/.env"
printf '%s\n' '模板配置' > "$source_dir/deploy/.env"
touch "$source_dir/config/native.json"
printf '仅新版存在\n' > "$source_dir/new-only.txt"
chmod 0700 "$target_dir/deploy/update.sh"
chmod 0755 "$source_dir/deploy/update.sh"
mkdir -p "$SOFTWARE_ROOT/deploy/lib"
printf '旧版本\n' > "$SOFTWARE_ROOT/deploy/lib/versions.env"

# 前两个归档成员均小于 512 字节；截在第三个成员的数据中间，GNU tar 会先写入前两个文件再报错。
head -c 4096 /dev/zero > "$temp/tail.bin"
tar --format=ustar -cf "$temp/truncated.tar" -C "$source_dir" ./deploy/update.sh ./new-only.txt -C "$temp" tail.bin
truncate -s 3072 "$temp/truncated.tar"

sync_shared_libraries() { printf '新版本\n' > "$SOFTWARE_ROOT/deploy/lib/versions.env"; }
ensure_global_env() { :; }
mktemp() {
    [[ "$failure" != mktemp ]] || return 41
    local template="${!#}" args=("$@")
    if [[ "$template" == /tmp/deploy-* ]]; then
        args[$#-1]="$temp/archives/${template##*/}"
    fi
    command mktemp "${args[@]}"
}
tar() {
    [[ "$failure" != archive ]] || return 42
    command tar "$@"
}
run_root() {
    case "$failure:$1" in
        directory:mkdir) return 43 ;;
        extract:tar) return 44 ;;
        partial-extract:tar)
            local tar_status
            cp -- "$temp/truncated.tar" "$5" || return $?
            if "$@"; then return 1; else tar_status=$?; fi
            cmp "$source_dir/deploy/update.sh" "$3/deploy/update.sh" || return 1
            cmp "$source_dir/new-only.txt" "$3/new-only.txt" || return 1
            touch "$temp/partial-extract"
            return "$tar_status"
            ;;
        partial-publish:mv)
            if [[ "$4" == "$SOFTWARE_ROOT"/.deploy-*/new/* ]]; then
                "$@" || return $?
                if [[ -e "$target_dir/new-only.txt" ]] && cmp -s "$source_dir/deploy/update.sh" "$target_dir/deploy/update.sh"; then
                    touch "$temp/partial-publish"
                    return 49
                fi
                return 0
            fi
            ;;
        copy:cp) [[ "$2" != -n ]] || return 45 ;;
        permissions:chmod) return 46 ;;
    esac
    "$@"
}
find() {
    [[ "$failure" != enumerate || "$1" != "$source_dir/config" ]] || return 47
    command find "$@"
}

caller_trap="$(trap -p EXIT)"
cp -a "$SOFTWARE_ROOT" "$temp/before"
for expectation in partial-extract:2 partial-publish:49 mktemp:41 archive:42 directory:43 extract:44 copy:45 permissions:46 enumerate:47; do
    failure="${expectation%:*}"
    if run_task "$app" update > "$temp/output" 2>&1; then
        echo "$failure 故障被报告为成功" >&2
        exit 1
    else
        status=$?
    fi
    [[ "$status" == "${expectation#*:}" ]]
    if [[ "$failure" == partial-* ]]; then [[ -f "$temp/$failure" ]]; fi
    [[ ! -e "$lifecycle_log" ]]
    if grep -q '已同步：' "$temp/output"; then exit 1; fi
    diff -r --no-dereference "$temp/before" "$SOFTWARE_ROOT"
    [[ "$(stat -c %a "$target_dir/deploy/update.sh")" == 700 ]]
    [[ -z "$(command ls -A -- "$temp/archives")" && "$(trap -p EXIT)" == "$caller_trap" ]]
done

failure=''
run_task "$app" sync
[[ ! -e "$lifecycle_log" ]]
run_task "$app" update
[[ "$(cat "$lifecycle_log")" == new ]]
cmp "$source_dir/new-only.txt" "$target_dir/new-only.txt"
[[ "$(cat "$SOFTWARE_ROOT/deploy/lib/versions.env")" == 新版本 ]]
[[ "$(cat "$target_dir/data/value")" == 用户数据 && "$(cat "$target_dir/deploy/.env")" == 用户配置 ]]
[[ -f "$target_dir/config/native.json" && -x "$target_dir/deploy/update.sh" ]]
[[ -z "$(command ls -A -- "$temp/archives")" && "$(trap -p EXIT)" == "$caller_trap" ]]
echo "同步失败保留旧版本、临时文件清理及成功重试验证通过"

# 桌面管理走实际命令入口；仓库只提供业务发现，查询或管理不能重新安装部署文件。
mkdir -p "$ROOT_DIR/fnos-desktop/deploy"
touch "$ROOT_DIR/fnos-desktop/deploy/install.sh"
echo 'exit 88' > "$ROOT_DIR/fnos-desktop/deploy/manage.sh"
desktop="$SOFTWARE_ROOT/fnos-desktop"
for action in status logs; do
    if main fnos-desktop "$action" > "$temp/output" 2>&1; then exit 1; fi
    grep -Fq '未发现 fnos-desktop 安装记录' "$temp/output"
    [[ ! -e "$desktop" ]]
done
mkdir -p "$desktop/deploy" "$desktop/state"
printf '%s\n' 'printf "已安装的管理脚本 %s\n" "$1"; exit "${FNOS_TEST_STATUS:-0}"' > "$desktop/deploy/manage.sh"
# 仅同步过脚本或已经卸载时，也不可控制宿主机上的同名服务。
if main fnos-desktop start > "$temp/output" 2>&1; then exit 1; fi
grep -Fq '未发现 fnos-desktop 安装记录' "$temp/output"
touch "$desktop/state/owned-units"
mv "$desktop/deploy/manage.sh" "$temp/manage.sh"
if main fnos-desktop logs > "$temp/output" 2>&1; then exit 1; fi
grep -Fq '缺少管理脚本' "$temp/output"
[[ ! -e "$desktop/deploy/manage.sh" ]]
mv "$temp/manage.sh" "$desktop/deploy/manage.sh"
cp -a -- "$SOFTWARE_ROOT" "$temp/before-management"
sync_task() { echo '意外同步' >&2; return 91; }
ensure_global_env() { echo '意外初始化全局配置' >&2; return 92; }
initialize_app_config() { echo '意外初始化应用配置' >&2; return 93; }
for action in status start stop restart logs uninstall; do
    main fnos-desktop "$action" > "$temp/output"
    grep -Fxq "已安装的管理脚本 $action" "$temp/output"
done
if FNOS_TEST_STATUS=3 main fnos-desktop status > "$temp/output"; then exit 1; else [[ $? == 3 ]]; fi
diff -r --no-dereference "$temp/before-management" "$SOFTWARE_ROOT"
echo "fnos-desktop 仅调用已安装管理入口并保留退出码"
