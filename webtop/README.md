# LinuxServer Webtop (Debian + XFCE)

官方镜像：`lscr.io/linuxserver/webtop:debian-xfce`。使用 Selkies 浏览器桌面，**不是 noVNC**；此服务运行在 Docker 内，不会安装宿主机 XFCE/Xorg。

## 安装与更新

在 deploy 仓库根目录运行：

```bash
sudo bash deploy.sh env
sudo bash deploy.sh webtop
# 更新
git pull
sudo bash deploy.sh env
sudo bash deploy.sh webtop update
```

首次安装若 `.secrets` 中 `WEBTOP_PASSWORD` 留空，会自动生成强密码并写入统一 .secrets；查看密码：

```bash
sudo grep '^WEBTOP_PASSWORD=' /vol3/1000/software/deploy/.secrets
```

如果 SOFTWARE_ROOT 不是 fnOS 默认值，请改成实际根目录。用户名默认 desktop。访问 `https://<NAS-IP>:7014/`，浏览器首次可能提示自签名证书；必须使用 **https**，不要写成 http。此镜像的视频/音频功能依赖安全上下文。

## 配置

普通配置在 `<SOFTWARE_ROOT>/deploy/.env`：

```dotenv
WEBTOP_IMAGE=lscr.io/linuxserver/webtop:debian-xfce
WEBTOP_BIND_IP=0.0.0.0
WEBTOP_HTTPS_PORT=7014
WEBTOP_PUID=1000
WEBTOP_PGID=1000
WEBTOP_USER=desktop
```

密码在 `<SOFTWARE_ROOT>/deploy/.secrets`：

```dotenv
WEBTOP_PASSWORD=
```

镜像是 LSIO 官方 registry（lscr.io），不参与 GHCR 镜像轮换。用户配置持久化至 `<SOFTWARE_ROOT>/webtop/data`；密钥文件保存在 `<SOFTWARE_ROOT>/webtop/state`。更新不会清理这些数据。

## 安全

只映射 HTTPS 3001，不映射 HTTP 3000。默认允许局域网访问，但**不要将 7014 直接暴露公网**；建议仅通过 EasyTier 或可信 HTTPS 反向代理及强认证访问。可设置 `WEBTOP_BIND_IP=127.0.0.1` 限制为宿主机回环。容器不挂载 Docker Socket、宿主机根目录，不启用 privileged/GPU；/config 内用户拥有数据。Webtop 桌面内可使用 sudo，所以不要共享宿主机敏感目录。

## 排障

```bash
docker logs --tail=100 webtop
docker ps --filter name=webtop
sudo bash deploy.sh webtop update
```

如果登录后白屏，先检查容器日志和系统是否满足 Docker `shm_size=1gb` 的内存需求；Webtop 官方文档：https://docs.linuxserver.io/images/docker-webtop/
