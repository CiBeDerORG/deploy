# FRPS

这个目录用于部署项目使用的 FRPS 服务端。

运行方式：

```text
Docker Compose
```

镜像：

```text
ghcr.io/cibeder/frps:dev-multi-latest
```

## 目录

```text
frps/
├── config/
│   └── frps.toml
├── data/
└── deploy/
    ├── docker-compose.yaml
    ├── install.sh
    └── update.sh
```

实际部署后位于：

```text
<SOFTWARE_ROOT>/frps/
```

## 配置

先在 deploy 仓库根目录初始化配置：

```bash
sudo bash deploy.sh env
```

普通配置：

```text
<SOFTWARE_ROOT>/deploy/.env
```

```dotenv
FRPS_BIND_PORT=7000
FRPS_DASHBOARD_PORT=7001
FRPS_PROXY_PORTS='["3389","7100-7800"]'
```

敏感配置：

```text
<SOFTWARE_ROOT>/deploy/.secrets
```

```dotenv
FRPS_DASHBOARD_USER=admin
FRPS_DASHBOARD_PASSWORD=
```

## 端口

| 用途 | 默认端口 |
| --- | ---: |
| FRPS 客户端连接 | 7000/TCP |
| Web Dashboard | 7001/TCP |
| HTTP vhost 宿主机入口 | 9080/TCP |
| HTTPS vhost 宿主机入口 | 9443/TCP |
| 自定义代理端口 | 由 FRPS_PROXY_PORTS 决定 |

固定映射：

```text
宿主机 9080 -> 容器 80
宿主机 9443 -> 容器 443
```

## FRPS_PROXY_PORTS

支持单个端口和连续范围：

```dotenv
FRPS_PROXY_PORTS='["3389","7100-7800","8001"]'
```

安装脚本会同时更新：

```text
frps/config/frps.toml
frps/deploy/docker-compose.yaml
```

生成内容包括：

- `allowPorts`
- Docker 宿主机端口映射

安装脚本会校验：

- 端口范围必须为 1-65535
- 端口不能重复
- 端口范围不能互相重叠
- 不能与 FRPS bind / dashboard 端口冲突
- 不能占用固定 vhost 相关端口

## 安装

在 deploy 仓库根目录：

```bash
sudo bash deploy.sh frps
```

安装成功后查看：

```bash
docker ps
docker logs -f frps
```

Dashboard：

```text
http://<服务器IP>:7001
```

登录账号和密码来自：

```text
FRPS_DASHBOARD_USER
FRPS_DASHBOARD_PASSWORD
```

## 只重新生成配置

如果只修改了 FRPS 端口配置，需要重新生成 TOML / Compose，而暂时不启动容器：

```bash
bash <SOFTWARE_ROOT>/frps/deploy/install.sh apply-config
```

## 持久化数据

数据目录：

```text
<SOFTWARE_ROOT>/frps/data/
```

客户端管理数据：

```text
<SOFTWARE_ROOT>/frps/data/clients.json
```

更新流程会在需要时把 `clients.json` 备份到：

```text
<SOFTWARE_ROOT>/frps/data/backup/
```

## 更新

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh frps update
```

## 常见排查

检查端口：

```bash
ss -lntup
```

查看容器：

```bash
docker ps --filter name=frps
```

查看日志：

```bash
docker logs --tail=200 frps
docker logs -f frps
```

如果修改了 `FRPS_PROXY_PORTS`，先确认没有与现有宿主机服务端口冲突。
