#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) fail "仅支持 install/update";; esac
require_root
assert_platform
load_settings
if [ "$MODE" = update ] && [ ! -f "$STATE/owned-units" ]; then
  fail "未发现安装记录，请先运行 sudo bash deploy.sh fnos-desktop"
fi
if [ ! -f "$STATE/owned-units" ] && { [ -e "$UNIT_VNC" ] || [ -e "$UNIT_WEB" ]; }; then
  fail "已有同名 systemd 服务，拒绝覆盖"
fi
if getent passwd "$FNOS_DESKTOP_USER" >/dev/null; then
  [ -f "$STATE/owned-user" ] && [ "$(cat "$STATE/owned-user")" = "$FNOS_DESKTOP_USER" ] ||
    fail "系统中已有同名非托管用户，请更改 FNOS_DESKTOP_USER"
  [ "$(getent passwd "$FNOS_DESKTOP_USER" | cut -d: -f6)" = "$HOME_DIR" ] ||
    fail "现有桌面用户 home 与项目记录不匹配"
elif [ -f "$STATE/owned-user" ]; then
  fail "安装记录中的用户不存在，请先排查后重装"
fi
echo "将安装宿主机 XFCE4 + TigerVNC + noVNC；不安装显示管理器，不执行全系统 upgrade"
packages=(xfce4 xfce4-terminal thunar dbus-x11 tigervnc-standalone-server tigervnc-tools novnc websockify fonts-noto-cjk openssl)
if [ "$FNOS_DESKTOP_APT_UPDATE" = true ]; then
  apt-get update || fail "apt-get update 失败，请检查系统软件源"
fi
apt-get -s --no-install-recommends --no-remove install "${packages[@]}" >/dev/null ||
  fail "APT 预检失败：可能存在依赖冲突或删除系统包的风险"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-remove "${packages[@]}" ||
  fail "APT 软件包安装失败，未更改 fnOS 默认启动"
for bin in tigervncserver tigervncpasswd websockify dbus-launch startxfce4 openssl python3; do
  command -v "$bin" >/dev/null || fail "安装后找不到 $bin"
done
[ -d /usr/share/novnc ] || fail "未找到 noVNC 静态文件目录"
install -d -m 0711 "$STATE" "$MODULE/data"
if ! getent passwd "$FNOS_DESKTOP_USER" >/dev/null; then
  useradd --create-home --home-dir "$HOME_DIR" --shell /bin/bash "$FNOS_DESKTOP_USER" ||
    fail "创建桌面用户失败"
  printf '%s\n' "$FNOS_DESKTOP_USER" > "$STATE/owned-user"
fi
group="$(id -gn "$FNOS_DESKTOP_USER")"
install -d -m 0700 -o "$FNOS_DESKTOP_USER" -g "$group" "$HOME_DIR/.vnc"
if [ -z "$FNOS_DESKTOP_VNC_PASSWORD" ]; then
  FNOS_DESKTOP_VNC_PASSWORD="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(8)))')" ||
    fail "密码生成失败"
  sed -i '/^FNOS_DESKTOP_VNC_PASSWORD=/d' "$SECRETS_FILE"
  printf '\nFNOS_DESKTOP_VNC_PASSWORD=%s\n' "$FNOS_DESKTOP_VNC_PASSWORD" >> "$SECRETS_FILE"
  chmod 0600 "$SECRETS_FILE"
  echo "已生成 VNC 密码，保存在 $SECRETS_FILE"
fi
[[ "$FNOS_DESKTOP_VNC_PASSWORD" =~ ^[A-Za-z0-9]{8}$ ]] ||
  fail "VNC 密码必须是 8 位 ASCII 字母数字；VncAuth 超过 8 位不会增加安全性"
# Write TigerVNC's obfuscated password file, never expose plaintext in ps or logs.
pass_tmp="$(mktemp "$HOME_DIR/.vnc/.passwd.XXXXXX")"
if ! printf '%s\n' "$FNOS_DESKTOP_VNC_PASSWORD" | tigervncpasswd -f > "$pass_tmp"; then
  rm -f "$pass_tmp"; fail "密码生成失败"
fi
chown "$FNOS_DESKTOP_USER:$group" "$pass_tmp"
chmod 0600 "$pass_tmp"
mv -f "$pass_tmp" "$HOME_DIR/.vnc/passwd"
# Stage as root in the root-owned state directory, then atomically rename over
# any user-created symlink; never open a user-controlled destination as root.
startup_tmp="$(mktemp "$STATE/.xstartup.XXXXXX")"
cat > "$startup_tmp" <<'EOF_XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
EOF_XSTARTUP
chown "$FNOS_DESKTOP_USER:$group" "$startup_tmp"
chmod 0750 "$startup_tmp"
mv -fT -- "$startup_tmp" "$HOME_DIR/.vnc/xstartup"
if [ ! -s "$STATE/tls.crt" ] || [ ! -s "$STATE/tls.key" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
    -keyout "$STATE/tls.key" -out "$STATE/tls.crt" -subj "/CN=fnos-desktop" >/dev/null 2>&1 ||
    fail "创建 HTTPS 证书失败"
fi
chown "$FNOS_DESKTOP_USER:$group" "$STATE/tls.key" "$STATE/tls.crt"
chmod 0600 "$STATE/tls.key"
chmod 0644 "$STATE/tls.crt"
cat > "$UNIT_VNC" <<EOF_VNC
[Unit]
Description=fnOS Desktop native XFCE4 (TigerVNC)
After=network.target
[Service]
Type=simple
User=$FNOS_DESKTOP_USER
Group=$group
Environment=HOME=$HOME_DIR
WorkingDirectory=$HOME_DIR
ExecStart=/usr/bin/tigervncserver :1 -fg -localhost yes -SecurityTypes VncAuth -PasswordFile $HOME_DIR/.vnc/passwd -geometry $FNOS_DESKTOP_RESOLUTION -depth 24 -xstartup $HOME_DIR/.vnc/xstartup
ExecStop=-/usr/bin/tigervncserver -kill :1
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF_VNC
cat > "$UNIT_WEB" <<EOF_WEB
[Unit]
Description=fnOS Desktop native noVNC HTTPS gateway
Requires=fnos-desktop-vnc.service
After=fnos-desktop-vnc.service
PartOf=fnos-desktop-vnc.service
[Service]
Type=simple
User=$FNOS_DESKTOP_USER
Group=$group
ExecStart=/usr/bin/websockify --ssl-only --cert $STATE/tls.crt --key $STATE/tls.key --web /usr/share/novnc $FNOS_DESKTOP_BIND_IP:$FNOS_DESKTOP_HTTPS_PORT 127.0.0.1:5901
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF_WEB
chmod 0644 "$UNIT_VNC" "$UNIT_WEB"
printf '%s\n' "managed by CiBeDerORG/deploy fnos-desktop" > "$STATE/owned-units"
systemctl daemon-reload
systemctl enable fnos-desktop-vnc.service fnos-desktop-novnc.service >/dev/null
systemctl restart fnos-desktop-vnc.service ||
  fail "桌面启动失败：journalctl -u fnos-desktop-vnc -n 60 --no-pager"
systemctl restart fnos-desktop-novnc.service ||
  fail "noVNC 启动失败：journalctl -u fnos-desktop-novnc -n 60 --no-pager"
systemctl is-active --quiet fnos-desktop-vnc.service || fail "VNC 未运行"
systemctl is-active --quiet fnos-desktop-novnc.service || fail "noVNC 未运行"
echo "原生宿主机桌面已启动，无需重启 fnOS"
echo "访问：https://<NAS-IP>:$FNOS_DESKTOP_HTTPS_PORT/vnc.html （自签名 HTTPS）"
echo "密码位置：$SECRETS_FILE"
echo "管理：sudo bash $MODULE/deploy/manage.sh status|start|stop|restart|logs|uninstall"
echo "注意：VNC 密码和自签名 HTTPS 不适合直接暴露公网"
