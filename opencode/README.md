# OpenCode V2

这个目录用于通过 Docker 部署 OpenCode V2 Web 服务。

镜像不是直接拉取固定 OpenCode 镜像，而是由仓库中的 Dockerfile 使用官方 V2 安装器构建本地镜像：

```text
opencode-local:latest
```

## 目录

```text
opencode/
├── config/
│   └── opencode.jsonc
├── data/
├── state/
├── workspace/
└── deploy/
    ├── Dockerfile
    ├── docker-compose.yaml
    ├── docker-entrypoint.sh
    ├── install.sh
    └── update.sh
```

实际部署后位于：

```text
<SOFTWARE_ROOT>/opencode/
```

## 配置

先初始化统一配置：

```bash
sudo bash deploy.sh env
```

`.env`：

```dotenv
OPENCODE_PORT=7003
MYAI_IP=203.0.113.10
BUILD_NO_PROXY=127.0.0.1,localhost
```

`.secrets`：

```dotenv
OPENCODE_SERVER_PASSWORD=
```

`OPENCODE_SERVER_PASSWORD` 为必填项。

OpenCode V2 当前 Basic Auth 用户名固定为：

```text
opencode
```

## MYAI_IP

仓库默认 `opencode.jsonc` 中的 `myai` provider 使用：

```text
http://<MYAI_IP>:8080/v1
```

因此 `MYAI_IP` 应填写 OpenCode 容器能够访问到的对应服务地址。

## 安装

```bash
sudo bash deploy.sh opencode
```

安装脚本会：

1. 校验统一配置。
2. 构建最新 OpenCode V2 本地镜像。
3. 启动容器。
4. 使用 Basic Auth 调用 `/api/health` 等待健康检查通过。

访问：

```text
http://<服务器IP>:7003
```

## Docker build 代理

服务器访问 OpenCode 官方安装地址较慢时，可以配置只用于构建阶段的代理。

推荐：

```dotenv
BUILD_HTTP_PROXY=http://host.docker.internal:7890
BUILD_HTTPS_PROXY=http://host.docker.internal:7890
BUILD_NO_PROXY=127.0.0.1,localhost
```

不要写：

```text
http://127.0.0.1:7890
```

Docker build 中的 `127.0.0.1` 指向构建容器自身，不是宿主机。

同时需要确保宿主机代理监听 Docker bridge 可以访问的地址。

这些代理变量只参与 Docker build，不会被写入最终 OpenCode 运行环境。

## 持久化

| 目录 | 用途 |
| --- | --- |
| `config/` | OpenCode 配置 |
| `data/` | OpenCode 数据 |
| `state/` | OpenCode 状态 |
| `workspace/` | 工作目录 |

更新时脚本会在 `data/backup/` 中备份检测到的数据库与认证数据。

## 更新

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh opencode update
```

更新会重新执行 Docker build，并通过 cache bust 强制检查并安装当前官方 V2 latest。

## 查看状态

```bash
docker ps --filter name=opencode
docker logs --tail=200 opencode
docker logs -f opencode
```

健康接口：

```text
http://127.0.0.1:<OPENCODE_PORT>/api/health
```

需要 Basic Auth：

```text
用户名: opencode
密码: OPENCODE_SERVER_PASSWORD
```

## 常见排查

### 外网访问不了

确认：

```bash
ss -lntp
docker ps
```

并检查：

- 云服务器安全组
- 系统防火墙
- `OPENCODE_PORT`
- 容器健康状态

### build 失败

查看完整构建输出：

```bash
cd <SOFTWARE_ROOT>/opencode/deploy
docker compose build --pull --progress=plain opencode
```

如果使用代理，优先确认 Docker 是否能访问宿主机代理。
