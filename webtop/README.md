# LinuxServer Webtop（Debian XFCE）

此服务在 Docker 容器中运行 LinuxServer 官方 Debian XFCE Webtop 镜像，通过浏览器访问完整 Linux 桌面。它不是在 fnOS 宿主机安装桌面，也不使用 noVNC；当前上游 Webtop 使用 Selkies 浏览器桌面流。

上游项目与文档：

- https://github.com/linuxserver/docker-webtop
- https://docs.linuxserver.io/images/docker-webtop/

## 安装与更新

Linux / fnOS：

    sudo bash deploy.sh env
    sudo bash deploy.sh webtop
    sudo bash deploy.sh webtop update

Windows 11（Docker Desktop）：

    .\deploy.ps1 env
    .\deploy.ps1 webtop
    .\deploy.ps1 webtop update

## 默认配置

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| 镜像 | lscr.io/linuxserver/webtop:debian-xfce | Debian + XFCE，支持 AMD64 / ARM64 |
| 监听地址 | 127.0.0.1 | 默认仅本机可访问 |
| HTTPS 端口 | 7014 | 映射到容器 3001 |
| PUID / PGID | 1000 / 1000 | 容器文件访问使用的宿主机 UID / GID |
| 桌面语言 | zh_CN.UTF-8 | 简体中文 locale |
| SHM | 1gb | 上游建议桌面容器设置共享内存 |

直接访问：

    https://127.0.0.1:7014/

默认只监听回环地址。如果要从其他电脑访问，在统一配置文件 $SOFTWARE_ROOT/deploy/.env 中将 WEBTOP_BIND_IP 改为 0.0.0.0（或指定 NAS 的可信 LAN / 私有网络 IPv4 地址），再执行更新：

    sudo bash deploy.sh webtop update

如果没有配置上游登录认证，请只在可信局域网 / 私有网络内使用，或放在带有强认证的反向代理之后。上游认证通过 WEBTOP_CUSTOM_USER 与 WEBTOP_PASSWORD 同时设置启用；两者必须同时设置或同时留空。不要把桌面直接暴露到公网。

Webtop 默认使用自签名 HTTPS 证书，首次访问时浏览器可能需要手动确认。当前 Compose 只发布 HTTPS 端口 3001，不发布供反向代理使用的 HTTP 端口 3000。

## 统一配置

普通配置位于 $SOFTWARE_ROOT/deploy/.env：

- WEBTOP_IMAGE：镜像地址，默认 lscr.io/linuxserver/webtop:debian-xfce。
- WEBTOP_BIND_IP：宿主机监听地址，默认 127.0.0.1。
- WEBTOP_PORT：宿主机 HTTPS 端口，默认 7014。
- WEBTOP_PUID / WEBTOP_PGID：容器文件用户和用户组 ID。可在 NAS 上执行 id username 查看。
- WEBTOP_LOCALE：桌面语言，默认 zh_CN.UTF-8。
- WEBTOP_SHM_SIZE：共享内存，默认 1gb。
- WEBTOP_CUSTOM_USER：可选登录用户名。

敏感配置位于 $SOFTWARE_ROOT/deploy/.secrets：

- WEBTOP_PASSWORD：可选登录密码。用户名和密码必须同时设置或同时留空；密码原样传递，不做额外长度或字符集限制。

## 数据持久化与共享目录

    $SOFTWARE_ROOT/webtop/data/config/   -> 容器 /config
    $SOFTWARE_ROOT/webtop/data/shared/   -> 容器 /shared

/config 保存 Webtop 用户目录、桌面设置和用户安装的软件数据；/shared 是用户主动选择使用的文件交换目录。不会挂载 Docker Socket，也不会默认挂载宿主机根目录或其他 NAS 共享目录。卸载服务默认保留这两个目录。

## 安全边界

- 默认仅绑定 127.0.0.1，避免无认证桌面直接暴露到局域网。
- 不启用 privileged，不挂载 /var/run/docker.sock，不映射宿主机设备。
- Webtop 桌面终端具备容器内 sudo 权限；能登录桌面的用户可获得容器内 root 权限。不要把未受保护的桌面入口暴露给不可信网络。
- 仅发布 HTTPS 3001；如需公网访问，应使用 HTTPS 反向代理和额外身份认证，并限制来源。

## 更新与日志

    sudo bash deploy.sh webtop update
    docker logs --tail=200 webtop
    docker logs -f webtop

更新会拉取上游镜像并重建 Webtop 容器，不会删除 data/config 或 data/shared。
