#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo "EasyHostAgent 卸载需要 root 权限" >&2; exit 1; }
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$MODULE/.." && pwd)"
staging="${EASYHOSTAGENT_STAGING_ROOT:-}"
if [[ -n "$staging" ]]; then
    [[ "$staging" == /* && -d "$staging" && ! -L "$staging" ]] ||
        { echo "隔离测试目录不合法" >&2; exit 1; }
    exec bash "$MODULE/native/scripts/uninstall.sh" --staging-root "$staging"
fi
mkdir -p "$SOFTWARE_ROOT/deploy/state"
exec 8>"$SOFTWARE_ROOT/deploy/state/easyhostagent.lock"
flock -n 8 || { echo "已有 EasyHostAgent 操作正在运行" >&2; exit 1; }
exec bash "$MODULE/native/scripts/uninstall.sh"
