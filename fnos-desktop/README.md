# fnOS Desktop — 宿主机原生 Debian XFCE4

在 **fnOS 宿主机** 通过 apt 安装 XFCE4、TigerVNC (Xvnc)、noVNC 和 websockify，并由 systemd 管理。本项目不是 Docker Webtop，也不共享 HDMI 桌面。无需独立安装 Xorg、LightDM、GDM，不修改默认启动目标，不运行全系统 apt upgrade/dist-upgrade；安装完通常无需重启 NAS。

> 该功能会修改 NAS 宿主机的软件包，属实验性集成，并非 fnOS 官方桌面方案。建议预先备份并保留 SSH 恢复通道；fnOS 大版本升级可能造成兼容性问题。

## 安装

在 Linux/fnOS 上的 deploy 仓库根目录执行：

```bash
git pull
sudo bash deploy.sh env
sudo nano /vol3/1000/software/deploy/.env
sudo bash deploy.sh fnos-desktop
```

访问 **https://<飞牛IP>:7015/vnc.html**，浏览器首次需要接受自签名 HTTPS 证书。noVNC 连接使用 VNC 密码，不使用 Linux 用户密码；密码在统一 secrets 里：

```bash
sudo grep '^FNOS_DESKTOP_VNC_PASSWORD=' /vol3/1000/software/deploy/.secrets
```

若 SOFTWARE_ROOT 不是 fnOS 默认值，请使用实际配置目录替换以上路径。

## 配置

普通配置位于统一的 `<SOFTWARE_ROOT>/deploy/.env`：

```dotenv
FNOS_DESKTOP_HTTPS_PORT=7015
FNOS_DESKTOP_BIND_IP=0.0.0.0
FNOS_DESKTOP_RESOLUTION=1920x1080
FNOS_DESKTOP_USER=fnosdesktop
FNOS_DESKTOP_APT_UPDATE=true
```

敏感配置位于统一的 `<SOFTWARE_ROOT>/deploy/.secrets`：

```dotenv
FNOS_DESKTOP_VNC_PASSWORD=
```

留空则首次安装自动生成 8 位 ASCII 字母数字密码。VNC VncAuth 最多识别 8 位密码，虽然网页版采用自签名 HTTPS，但**仍然不能将 7015 直接暴露公网**。推荐使用 EasyTier 私网或带额外登录验证的可信 HTTPS 反向代理。VNC TCP 5901 仅绑定宿主机 localhost，不能被局域网直接访问。

桌面使用非 root 用户，**不会自动授予 sudo**。个人应用可以安装到主目录；安装宿主机 apt 软件请通过 SSH 使用已有管理员 sudo。不要给网页桌面账户随意开通免密码 sudo。

## 更新、管理与卸载

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh fnos-desktop update

sudo bash /vol3/1000/software/fnos-desktop/deploy/manage.sh status
sudo bash /vol3/1000/software/fnos-desktop/deploy/manage.sh stop
sudo bash /vol3/1000/software/fnos-desktop/deploy/manage.sh start
sudo bash /vol3/1000/software/fnos-desktop/deploy/manage.sh restart
sudo bash /vol3/1000/software/fnos-desktop/deploy/manage.sh logs
sudo bash /vol3/1000/software/fnos-desktop/deploy/manage.sh uninstall
```

卸载只移除本项目的 systemd 服务，不会自动删除宿主机 APT 包、桌面用户、密码和用户文件（避免影响其他系统软件）。桌面 home 在 `<SOFTWARE_ROOT>/fnos-desktop/data/home`，更新同步时保留 `data/` 与 `state/`。

## 排障

```bash
sudo systemctl status fnos-desktop-vnc fnos-desktop-novnc
sudo journalctl -u fnos-desktop-vnc -n 100 --no-pager
sudo journalctl -u fnos-desktop-novnc -n 100 --no-pager
sudo ss -lntp | grep -E '5901|7015'
```

Docker Webtop 仍可独立安装在 HTTPS 7014；宿主机 fnos-desktop 使用 HTTPS 7015，两者互不影响。
