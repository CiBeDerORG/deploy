# Portainer CE

这个目录用于部署 Portainer CE LTS。

## 目录

```text
portainer/
├── data/
└── deploy/
    ├── docker-compose.yaml
    ├── install.sh
    └── update.sh
```

实际部署后位于：

```text
<SOFTWARE_ROOT>/portainer/
```

## 配置

先初始化统一配置：

```bash
sudo bash deploy.sh env
```

`.env`：

```dotenv
PORTAINER_HTTP_PORT=7004
PORTAINER_EDGE_PORT=8000
PORTAINER_EDGE_CONTAINER_PORT=8000
```

`.secrets`：

```dotenv
PORTAINER_ADMIN_PASSWORD=
```

`PORTAINER_ADMIN_PASSWORD`：

- 必填
- 至少 12 个字符
- 只应保存在真实 `.secrets`

## 安装

```bash
sudo bash deploy.sh portainer
```

安装脚本会拉取：

```text
portainer/portainer-ce:lts
```

并启动：

```text
portainer
```

访问：

```text
http://<服务器IP>:7004
```

管理员用户名：

```text
admin
```

管理员密码为：

```text
PORTAINER_ADMIN_PASSWORD
```

## 持久化

Portainer 数据：

```text
<SOFTWARE_ROOT>/portainer/data/
```

Compose 还会挂载：

```text
/var/run/docker.sock
```

因此 Portainer 可以直接管理宿主机 Docker。

## Edge Agent 端口

模板里保留：

```dotenv
PORTAINER_EDGE_PORT=8000
PORTAINER_EDGE_CONTAINER_PORT=8000
```

但当前 `docker-compose.yaml` 中 Edge Agent Tunnel 映射默认是注释状态，不会自动开放 8000。

只有确实需要 Edge Agent 时，再取消对应 Compose 端口映射。

## 更新

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh portainer update
```

更新会拉取当前 LTS 镜像并重建服务，`data/` 不会被删除。

## 查看状态

```bash
docker ps --filter name=portainer
docker logs --tail=200 portainer
docker logs -f portainer
```

## 安全建议

Portainer 拥有宿主机 Docker Socket 的管理能力，因此 Web 管理入口应只对可信网络或可信来源开放。

如果公网访问，至少应：

- 使用强管理员密码
- 配置防火墙 / 安全组来源限制
- 不开放不需要的 Edge Agent 端口
