# EasyHostAgent · Docker / GHCR 部署（Linux、fnOS）

EasyHostAgent 使用 GitHub Actions 构建的 AMD64/ARM64 镜像 `ghcr.io/cibederorg/easyhostagent:feat-docker-app-store`，由 `deploy.sh` 下载并以单个 Docker Compose 容器运行。目标机器**不编译 Go，也不下载原生二进制**。Agent 只响应 EasyNetTopo 的请求，不发送心跳。

## 1. 配置文件

使用 `<SOFTWARE_ROOT>/deploy/.env`；Ubuntu 默认 `/software/deploy/.env`，fnOS 默认 `/vol3/1000/software/deploy/.env`。该项目不需要在统一 `.secrets` 中新增管理员账号、密码或 Token。

```dotenv
EASYHOSTAGENT_IMAGE=ghcr.io/cibederorg/easyhostagent:feat-docker-app-store
# 可信隔离网络可改成 http，公网建议 https。
EASYHOSTAGENT_TRANSPORT=https
# 0.0.0.0 监听所有宿主机 IPv4 网卡，127.0.0.1 仅本机。
EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018
EASYHOSTAGENT_LOG_LEVEL=info
EASYHOSTAGENT_DATA_DIR=/var/lib/easyhostagent
# 留空继承统一 SOFTWARE_ROOT。
EASYHOSTAGENT_SOFTWARE_ROOT=
# 配对后授权的 控制端UUID/来源UUID，可逗号分隔。
EASYHOSTAGENT_APP_GRANTS=
```

`DOCKER_IMAGE_SOURCE=mirror` 时沿用 deploy 仓库的 GHCR 加速轮换机制，默认 `original`。当前 `EASYHOSTAGENT_IMAGE` 是开发分支滚动镜像；生产建议固定成功构建的 `sha-完整Git提交` 标签。

`EASYHOSTAGENT_LISTEN_ADDRESS` 定义**宿主机对外绑定地址和端口**。Agent 在容器内自动监听同一端口的 `0.0.0.0`，无需单独配置容器 IP。请勿把 `0.0.0.0` 误认为仅限内网，真正的可达范围取决于防火墙与路由。

## 2. 运行条件与数据安全

要求 Linux/fnOS、Docker Engine、Docker Compose v2、Bash、root、`flock`；GHCR 镜像提供 Docker CLI/Compose、Bash 等执行依赖，宿主机无需安装 Go。镜像支持 AMD64 与 ARM64，未设置额外的 CPU/RAM 门槛。

**重要**：容器以 root 运行、挂载 `/var/run/docker.sock`，具有管理宿主机 Docker 的能力（接近宿主机 root 权限）。请只授权可信的 EasyNetTopo 控制端，限制 7018 端口访问来源；HTTP 明文会泄露一次性配对码与管理 Token，禁止直接暴露公网。

以下宿主机路径会以相同的绝对路径映射到容器：

- `EASYHOSTAGENT_SOFTWARE_ROOT`：默认统一 `SOFTWARE_ROOT`，例如 `/software` 或 `/vol3/1000/software`。Agent 安装的应用会出现在 `<SOFTWARE_ROOT>/.easyhostagent-apps/`。
- `EASYHOSTAGENT_DATA_DIR`：默认 `/var/lib/easyhostagent`，保留 Agent UUID、私钥、配对/授权状态、安装包缓存及应用操作记录。要求宿主机目录为 root:root、0700，首次不存在则自动创建。
- `/var/run/docker.sock`：只连接现有宿主机 Docker Engine，不在容器里启动新的 daemon。

如果同机已经安装了原生 `easyhostagent.service`，部署脚本会阻止两个实例同时运行。需要切换时先手动 `sudo systemctl disable --now easyhostagent.service`，会保留原生 Agent 身份和数据目录，再运行 Docker 安装。更新不会覆盖旧有配对数据。不要同时运行原生和 Docker Agent。

## 3. 配对与应用授权

首次启动会生成 Agent UUID 和 TLS 身份。使用 Docker 查看：

```bash
sudo docker exec easyhostagent /usr/local/bin/easyhostagent -identity
sudo docker exec easyhostagent /usr/local/bin/easyhostagent -pairing-code
```

配对码由 Agent 本地安全生成，默认 10 分钟有效，不需要在 `.secrets` 手工录入。配对成功后控制端获得一次性返回的管理 Token，Agent 只保存其摘要。

EasyNetTopo 添加主机时填写 `http://服务器IP:7018`（HTTP）或 `https://服务器IP:7018`（HTTPS，校验固定指纹）。HTTP/HTTPS 都需要现有配对授权，不能直接匿名调用安装、卸载、状态 API。

来源应用安装/卸载额外要求 `EASYHOSTAGENT_APP_GRANTS=控制端UUID/来源UUID`，多个授权用逗号隔开；留空仍可完成配对和状态查询，但不允许执行应用操作。安装包还遵循 Agent 现有的来源及本机信任审批机制。

## 4. 安装

```bash
cd /software/deploy
git switch feat/docker-app-store
git pull --ff-only origin feat/docker-app-store
sudo bash deploy.sh env
sudoedit /software/deploy/.env
sudo bash deploy.sh easyhostagent install
```

fnOS 以其部署仓库所在目录执行相同命令，将 `.env` 路径改为 `/vol3/1000/software/deploy/.env`。

查看容器和状态：

```bash
sudo docker ps -a --filter name=easyhostagent
sudo docker logs --tail 60 easyhostagent
```

上面第一条命令的容器名为 `easyhostagent`，可直接使用 `sudo docker ps -a --filter name=easyhostagent` 查询。启用 HTTP 时：

```bash
curl -fsS http://127.0.0.1:7018/v1/health
```

启用 HTTPS 自签名模式时，仅对**无凭据健康检查**可用：

```bash
curl -kfsS https://127.0.0.1:7018/v1/health
```

## 5. 更新

```bash
cd /software/deploy
git pull --ff-only origin feat/docker-app-store
sudo bash deploy.sh easyhostagent update
```

每次更新拉取 GHCR 镜像并重建本项目容器。保留既有数据目录、Agent 身份、配对授权和已安装的其他 Docker 应用。镜像拉取失败时旧容器保持不变。

## 6. 卸载（默认保留数据）

```bash
sudo bash deploy.sh easyhostagent uninstall
```

仅停止并删除当前 Compose 项目管理的 `easyhostagent` 容器/网络，不删除宿主机数据目录、软件目录、既有 Docker 应用、镜像、`.env` 或 `.secrets`。如需清除这些状态必须另行明确确认。
