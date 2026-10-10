# FlatNas

[FlatNas 官网](https://flatnas.top/) · [上游项目](https://github.com/Garry-QD/FlatNas) · [官方镜像](https://hub.docker.com/r/qdnas/flatnas)

基于上游官方 Docker 镜像 `qdnas/flatnas:latest` 部署个人导航页与 NAS 仪表盘。服务监听容器内 `3000/TCP`；本仓库默认映射宿主机 `23000/TCP`。不在服务器上重新构建上游源码。

## 快速部署

在 `CiBeDerORG/deploy` 仓库根目录执行：

```bash
sudo bash deploy.sh env
sudo nano /software/deploy/.env
sudo bash deploy.sh flatnas
```

fnOS 默认统一配置位置为 `/vol3/1000/software/deploy/.env`。如果仓库使用自定义 SOFTWARE_ROOT，请编辑对应目录的 `deploy/.env`。

普通配置位于统一 `.env`：

```dotenv
FLATNAS_HTTP_PORT=23000
FLATNAS_BIND_IP=0.0.0.0
FLATNAS_DOCKER_SOCKET=false
```

可选代理地址放在统一 `.secrets`（其中可能含认证凭据）：

```dotenv
FLATNAS_PROXY_URL=
```

安装后访问 `http://<设备局域网IP>:23000`，并立即修改上游默认管理密码（`admin`）。`FLATNAS_BIND_IP=127.0.0.1` 可以仅允许本机/反向代理访问；需要从 EasyTier 或局域网访问时，请绑定相应可达的地址并使用防火墙控制来源。

## 数据与挂载

仓库部署后，数据保存在 `<SOFTWARE_ROOT>/flatnas/`：

| 宿主机目录 | 容器目录 | 用途 |
| --- | --- | --- |
| `data/` | `/app/server/data` | 配置、导航、数据库等 |
| `doc/` | `/app/server/doc` | 文件传输 |
| `music/` | `/app/server/music` | 音乐 |
| `PC/` | `/app/server/PC` | 桌面背景 |
| `APP/` | `/app/server/APP` | 移动端背景 |

安装和更新均不删除这些目录。迁移或重装前仍建议整体备份。Docker 会在第一次创建挂载时生成空目录，不会导入其他已有 FlatNas 安装的数据。

## 可选 Docker 管理

上游官方 Compose 挂载 `/var/run/docker.sock` 以启用 Docker 管理。本仓库为降低默认权限，初始设置为 `FLATNAS_DOCKER_SOCKET=false`。

确实需要 FlatNas 管理此宿主机 Docker（例如查看和重启容器、检测镜像更新）时，编辑统一 `.env`：

```dotenv
FLATNAS_DOCKER_SOCKET=true
```

之后重新部署：`sudo bash deploy.sh flatnas update`。该开关仅授权 **FlatNas 所在机器的宿主机 Docker**，不会自动发现或管理另一台机器的 Docker。Docker Socket 近似宿主机管理员权限，应限制 FlatNas 登录账户、管理端口来源和上游自动升级功能的影响范围。

## 可选后端代理

`FLATNAS_PROXY_URL` 对应上游 `PROXY_URL` 环境变量，支持 `http://`、`https://`、`socks5://`、`socks5h://`。如果代理由同一宿主机上的另一个 Docker 容器提供，应使用 FlatNas 容器可访问的地址；`127.0.0.1` 指的是 FlatNas 容器自身，不是宿主机或其他容器。未配置时保持空白。

## 更新、状态和日志

```bash
# 在仓库克隆目录执行
git pull
sudo bash deploy.sh env
sudo bash deploy.sh flatnas update

docker ps --filter name=flatnas
docker logs --tail=100 flatnas
docker logs -f flatnas
```

`flatnas update` 拉取上游最新 `latest` 镜像并重建容器，保留上述持久化目录。更新前建议备份 `data/`。如需只同步仓库脚本、不重启现有服务：`sudo bash deploy.sh flatnas sync`。

## 安全注意

- 管理页面默认不应直接向整个公网开放；推荐使用 EasyTier 私网访问或可信反向代理及 HTTPS。
- 首次登录立即更改 FlatNas 默认密码 `admin`。
- FlatNas 使用 Docker Socket 时可以控制宿主机容器；不要对不可信访问者开放。
- `FLATNAS_PROXY_URL` 若包含认证信息，只能存放在真实 `.secrets`，不要提交到 Git。
