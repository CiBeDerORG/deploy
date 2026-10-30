#!/usr/bin/env bash
# Shared helpers for native fnOS Desktop
set -Eeuo pipefail
umask 077
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$(cd -- "$HERE/.." && pwd)"
ROOT="$(cd -- "$MODULE/.." && pwd)"
ENV_FILE="$ROOT/deploy/.env"
SECRETS_FILE="$ROOT/deploy/.secrets"
STATE="$MODULE/state"
HOME_DIR="$MODULE/data/home"
UNIT_VNC=/etc/systemd/system/fnos-desktop-vnc.service
UNIT_WEB=/etc/systemd/system/fnos-desktop-novnc.service
fail() { printf 'fnOS Desktop: %s\n' "$*" >&2; exit 1; }
require_root() { [ "$(id -u)" -eq 0 ] || fail "请使用 sudo/root 执行"; }
load_values() {
  local file="$1" line key value n=0
  [ -f "$file" ] || fail "缺少 $file；先执行 sudo bash deploy.sh env"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|\#*) continue;; esac
    [[ "$line" == *=* ]] || fail "$file:$n 需要 KEY=VALUE"
    key="${line%%=*}"
    key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//')"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]] || fail "$file:$n 无效变量名"
    if [ -n "$value" ]; then
      case "${value:0:1}" in
        '"') [ "${value: -1}" = '"' ] || fail "$file:$n 引号不闭合"; value="${value:1:${#value}-2}";;
        "'") [ "${value: -1}" = "'" ] || fail "$file:$n 引号不闭合"; value="${value:1:${#value}-2}";;
      esac
    fi
    case "$key" in FNOS_DESKTOP_*|TZ) printf -v "$key" '%s' "$value"; export "$key";; esac
  done < "$file"
}
load_settings() {
  load_values "$ENV_FILE"
  load_values "$SECRETS_FILE"
  FNOS_DESKTOP_USER="${FNOS_DESKTOP_USER:-fnosdesktop}"
  FNOS_DESKTOP_BIND_IP="${FNOS_DESKTOP_BIND_IP:-0.0.0.0}"
  FNOS_DESKTOP_HTTPS_PORT="${FNOS_DESKTOP_HTTPS_PORT:-7015}"
  FNOS_DESKTOP_RESOLUTION="${FNOS_DESKTOP_RESOLUTION:-1920x1080}"
  FNOS_DESKTOP_APT_UPDATE="${FNOS_DESKTOP_APT_UPDATE:-true}"
  FNOS_DESKTOP_VNC_PASSWORD="${FNOS_DESKTOP_VNC_PASSWORD:-}"
  [[ "$FNOS_DESKTOP_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || fail "FNOS_DESKTOP_USER 格式非法"
  [ "$FNOS_DESKTOP_USER" != root ] || fail "桌面禁止使用 root"
  [[ "$FNOS_DESKTOP_BIND_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail "FNOS_DESKTOP_BIND_IP 必须是 IPv4 地址"
  [[ "$FNOS_DESKTOP_HTTPS_PORT" =~ ^[0-9]+$ ]] || fail "端口必须是数字"
  (( 10#$FNOS_DESKTOP_HTTPS_PORT >= 1 && 10#$FNOS_DESKTOP_HTTPS_PORT <= 65535 )) || fail "端口必须在 1..65535"
  [[ "$FNOS_DESKTOP_RESOLUTION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || fail "分辨率格式应为 1920x1080"
  case "$FNOS_DESKTOP_APT_UPDATE" in true|false) ;; *) fail "FNOS_DESKTOP_APT_UPDATE 只能为 true/false";; esac
  [[ "$MODULE" != *[[:space:]]* ]] || fail "软件安装目录不能包含空白字符"
}
assert_platform() {
  [ -e /etc/debian_version ] || fail "仅支持 Debian 系宿主机（含适配的 fnOS）"
  command -v apt-get >/dev/null || fail "缺少 apt-get"
  command -v dpkg-query >/dev/null || fail "缺少 dpkg-query"
  command -v systemctl >/dev/null || fail "缺少 systemd"
  [ "$(ps -p 1 -o comm= | tr -d ' ')" = systemd ] || fail "PID 1 不是 systemd，拒绝修改服务"
}
