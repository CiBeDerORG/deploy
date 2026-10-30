#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"
require_root
ACTION="${1:-status}"
case "$ACTION" in
  status) systemctl --no-pager --full status fnos-desktop-vnc.service fnos-desktop-novnc.service ;;
  start) systemctl start fnos-desktop-vnc.service fnos-desktop-novnc.service ;;
  stop) systemctl stop fnos-desktop-novnc.service fnos-desktop-vnc.service ;;
  restart) systemctl restart fnos-desktop-vnc.service fnos-desktop-novnc.service ;;
  logs) journalctl -u fnos-desktop-vnc.service -u fnos-desktop-novnc.service -n 120 --no-pager ;;
  uninstall)
    [ -f "$STATE/owned-units" ] || fail "缺少项目服务所有权标记，拒绝删除"
    systemctl disable --now fnos-desktop-novnc.service fnos-desktop-vnc.service || true
    rm -f -- "$UNIT_VNC" "$UNIT_WEB"
    systemctl daemon-reload
    rm -f -- "$STATE/owned-units"
    echo "已移除原生桌面服务；APT 软件包、用户、密码与数据均保留"
    ;;
  *) fail "支持 status / start / stop / restart / logs / uninstall" ;;
esac
