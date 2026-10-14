# Deploy

统一管理 Linux / fnOS 上的常用服务部署，并提供 EasyTier OpenWrt 原生安装脚本。

仓库本身可以放在任意目录；真正运行的服务文件会由根目录 `deploy.sh` 同步到：

```text
<SOFTWARE_ROOT>/<服务名>
```

普通配置与敏感配置统一放在：

```text
<SOFTWARE_ROOT>/deploy/.env
<SOFTWARE_ROOT>/deploy/.secrets
```

> `.env` / `.secrets` 是运行配置，不应提交到 Git。仓库中的 `.env.example` 与 `.secrets.example` 只是模板。

## 服务一览

| 服务 | 默认端口 / 入口 | 部署方式 | 详细文档 |
| --- | --- | --- | --- |
| OpenCode V2 | `7003/TCP` | Docker Compose | [opencode/README.md](./opencode/README.md) |
| FRPS | `7000/TCP`，后台 `7001/TCP` | Docker Compose | [frps/README.md](./frps/README.md) |
| EasyTier | Core `7005`，RPC `7006`，Web `7007`，Config `7008/UDP` | Docker / OpenWrt | [easytier/README.md](./easytier/README.md) |
| Portainer CE | `7004/TCP` | Docker Compose | [portainer/README.md](./portainer/README.md) |
| FlatNas | `7009/TCP` | Docker Compose | [flatnas/README.md](./flatnas/README.md) |
| Sub2API | `7010/TCP` | Docker Compose（含 PostgreSQL、Redis） | [sub2api/README.md](./sub2api/README.md) |
| Mihomo / MetaCubeXD 完整版 | 代理 `7011/TCP`（宿主机）、Web/Agent `7012/TCP`、内核 API `7013/TCP` | Docker Compose | [mihomo/README.md](./mihomo/README.md) |
| GitHub Actions Runner | 无固定 Web 端口 | systemd | [github-runner/README.md](./github-runner/README.md) |

## 一、运行环境

Docker 服务需要：

- Linux / fnOS
- Bash
- root 或 sudo 权限
- Docker
- Docker Compose v2 Plugin（命令为 `docker compose`）

GitHub Runner 还需要：

- systemd
- curl
- tar

EasyTier 的 OpenWrt 节点不需要 Docker，使用独立脚本：

```text
easytier/openwrt/install.sh
```

## 二、快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/CiBeDerORG/deploy.git
cd deploy
```

### 2. 初始化统一配置

```bash
sudo bash deploy.sh env
```

默认软件根目录：

| 系统 | 默认 SOFTWARE_ROOT |
| --- | --- |
| Ubuntu / 普通 Linux | `/software` |
| fnOS | `/vol3/1000/software` |

如果首次部署就要使用其他目录，例如 `/srv/software`：

```bash
sudo env SOFTWARE_ROOT=/srv/software bash deploy.sh env
```

初始化后会得到：

```text
<SOFTWARE_ROOT>/deploy/.env
<SOFTWARE_ROOT>/deploy/.secrets
```

脚本会把这两个真实配置文件设置为：

```text
root:root 0600
```

### 3. 修改配置

Ubuntu 默认：

```bash
sudo nano /software/deploy/.env
sudo nano /software/deploy/.secrets
```

fnOS 默认：

```bash
sudo nano /vol3/1000/software/deploy/.env
sudo nano /vol3/1000/software/deploy/.secrets
```

普通配置写入 `.env`，例如端口、路径、地址、角色、开关。

敏感配置写入 `.secrets`，例如密码、Token、密钥。

### 4. 安装服务

查看可安装服务：

```bash
bash deploy.sh list
```

安装：

```bash
sudo bash deploy.sh opencode
sudo bash deploy.sh frps
sudo bash deploy.sh easytier
sudo bash deploy.sh portainer
sudo bash deploy.sh flatnas
sudo bash deploy.sh sub2api
sudo bash deploy.sh mihomo
sudo bash deploy.sh github-runner
```

也可以显式写 `install`：

```bash
sudo bash deploy.sh frps install
```

### 5. 更新

先拉取仓库：

```bash
git pull
```

同步新增配置项：

```bash
sudo bash deploy.sh env
```

再更新目标服务：

```bash
sudo bash deploy.sh <服务名> update
```

例如：

```bash
sudo bash deploy.sh easytier update
```

## 三、deploy.sh 命令

```text
bash deploy.sh
bash deploy.sh --help
bash deploy.sh list
sudo bash deploy.sh env

sudo bash deploy.sh <服务名>
sudo bash deploy.sh <服务名> install
sudo bash deploy.sh <服务名> update
sudo bash deploy.sh <服务名> sync
sudo bash deploy.sh proxy connect <容器名>
sudo bash deploy.sh proxy disconnect <容器名>
sudo bash deploy.sh proxy status [容器名]
```

含义：

| 命令 | 作用 |
| --- | --- |
| `deploy.sh` | 交互选择服务 |
| `deploy.sh list` | 列出当前可部署服务 |
| `deploy.sh env` | 初始化、迁移并补齐统一配置 |
| `deploy.sh <服务>` | 同步文件并安装 |
| `deploy.sh <服务> install` | 与上一条相同 |
| `deploy.sh <服务> update` | 同步最新文件后执行服务更新脚本 |
| `deploy.sh <服务> sync` | 只同步仓库文件，不启动或更新服务 |
| `deploy.sh proxy connect/disconnect <容器名>` | 动态接入/断开 Mihomo 的 proxy-net 内部共享网络，不修改业务 Compose |
| `deploy.sh proxy status [容器名]` | 查看共享网络成员或单容器接入状态 |

## 四、目录结构

典型运行目录：

```text
<SOFTWARE_ROOT>/
├── deploy/
│   ├── .env
│   └── .secrets
├── opencode/
│   ├── config/
│   ├── data/
│   ├── state/
│   ├── workspace/
│   └── deploy/
├── frps/
│   ├── config/
│   ├── data/
│   └── deploy/
├── easytier/
│   ├── data/
│   └── deploy/
├── portainer/
│   ├── data/
│   └── deploy/
├── flatnas/
│   ├── data/ doc/ music/ PC/ APP/
│   └── deploy/
├── sub2api/
│   ├── data/app/ data/postgres/ data/redis/
│   └── deploy/
├── mihomo/
│   ├── data/config.yaml
│   └── deploy/
└── github-runner/
    ├── data/
    └── deploy/
```

根 `deploy.sh` 同步服务目录时会保留运行数据，重点包括：

```text
deploy/.env
deploy/.secrets
data/
state/
workspace/
backup/
```

因此仓库更新不会主动覆盖服务的持久化数据。

## 五、统一配置

### .env

默认模板：

```dotenv
SOFTWARE_ROOT=/software
TZ=Asia/Shanghai

FRPS_BIND_PORT=7000
FRPS_DASHBOARD_PORT=7001
OPENCODE_PORT=7003
PORTAINER_HTTP_PORT=7004

EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_WEB_PORT=7007
EASYTIER_CONFIG_PORT=7008
FLATNAS_HTTP_PORT=7009
SUB2API_HTTP_PORT=7010
MIHOMO_MIXED_PORT=7011
MIHOMO_API_PORT=7012
MIHOMO_CORE_API_PORT=7013
```

### .secrets

默认模板：

```dotenv
OPENCODE_SERVER_PASSWORD=

FRPS_DASHBOARD_USER=admin
FRPS_DASHBOARD_PASSWORD=

PORTAINER_ADMIN_PASSWORD=

FLATNAS_PROXY_URL=

# Sub2API 数据库、Redis、管理员和持久化加密密钥：见 .secrets.example
# Mihomo API 和代理认证：见 .secrets.example
GITHUB_RUNNER_TOKEN=
```

### 配置解析规则

服务安装脚本不会直接 `source .env` 或 `source .secrets`。

脚本只把文件按 `KEY=VALUE` 读取，再导出成当前进程环境，因此密码里的特殊字符不会被当作 Shell 命令执行。

例如：

```dotenv
PASSWORD=abc$123&x#y
TOKEN='abc$123&x#y'
OTHER="a value with spaces"
```

规则：

- 空行和以 `#` 开头的整行注释会忽略。
- 变量名必须符合 `[A-Za-z_][A-Za-z0-9_]*`。
- 最外层成对的单引号或双引号会移除。
- 值中的 `$`、`&`、反引号、命令替换、变量引用都按字面值处理。
- 不支持 `export KEY=VALUE`，请直接使用 `KEY=VALUE`。

## 六、各服务快速配置

### FRPS

`.env`：

```dotenv
FRPS_BIND_PORT=7000
FRPS_DASHBOARD_PORT=7001
FRPS_PROXY_PORTS='["3389","7100-7800"]'
```

`.secrets`：

```dotenv
FRPS_DASHBOARD_USER=admin
FRPS_DASHBOARD_PASSWORD=
```

安装：

```bash
sudo bash deploy.sh frps
```

默认后台：

```text
http://<服务器IP>:7001
```

`FRPS_PROXY_PORTS` 会同时生成 FRPS `allowPorts` 和 Docker 端口映射。

固定 vhost 映射：

```text
9080 -> 容器 80
9443 -> 容器 443
```

详细说明：[frps/README.md](./frps/README.md)

### OpenCode V2

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

安装：

```bash
sudo bash deploy.sh opencode
```

默认入口：

```text
http://<服务器IP>:7003
```

Basic Auth 用户名固定为：

```text
opencode
```

详细说明：[opencode/README.md](./opencode/README.md)

### EasyTier

Docker 使用同一个容器部署两种角色：

- `cloud`：同时运行 Web Console、Config Server、**连接本机 Config Server 的云端 Core**。
- `intranet`：仅运行 Core，连接云端 Web Config Server。

默认端口：

```dotenv
EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_WEB_PORT=7007
EASYTIER_CONFIG_PORT=7008
```

云端 `.env`：

```dotenv
EASYTIER_ROLE=cloud
EASYTIER_PRIVILEGED=false
EASYTIER_WEB_API_HOST=http://<公网IP>:7007
EASYTIER_CONFIG_SERVER=
```

cloud Core 自动连接 `udp://127.0.0.1:7008/admin`。云端的**网络名称、网络密钥、虚拟 IPv4、Listener 和安全 flags 均在 Web 管理页面配置**，不再要求 `.env/.secrets` 提前填写网络身份。

进入云端 `7007` 页面，在对应机器新建网络实例，按照原组网填写网络名、密钥、IPv4（例如 `10.10.10.1/24`），并设置 `7005/TCP+UDP` 两个 Listener。

**重要：** 云端 Core 由 Web 接管后，原来静态 `cloud.toml` 所强制的 no-relay 限制不再存在。若不希望云端中继业务流量，必须在 Web **云端实例**的高级配置中设置 `disable_relay_data=true`、`relay_all_peer_rpc=true`、`enable_exit_node=false`；Web 可以再次修改这些设置，部署脚本无法强制锁定。

从旧版静态云端模式升级之前应备份 `/software/easytier/data/`。旧 `data/cloud-core/cloud.toml` 不再自动加载，也不会自动导入 Web；升级后需在 Web 中重新创建原有云端网络，期间云端 Peer 可能短暂不可用。

内网 `.env`：

```dotenv
EASYTIER_ROLE=intranet
EASYTIER_PRIVILEGED=true
EASYTIER_CONFIG_SERVER=udp://<公网服务器IP>:7008/admin
```

详细说明（含 Web、升级、OpenWrt）：[easytier/README.md](./easytier/README.md)

### Portainer

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

管理员密码至少 12 个字符。

安装：

```bash
sudo bash deploy.sh portainer
```

默认入口：

```text
http://<服务器IP>:7004
```

详细说明：[portainer/README.md](./portainer/README.md)

### FlatNas

使用官方镜像 `qdnas/flatnas:latest`，默认访问地址为 `http://<设备IP>:7009`。

`.env`：

```dotenv
FLATNAS_HTTP_PORT=7009
FLATNAS_BIND_IP=0.0.0.0
FLATNAS_DOCKER_SOCKET=false
```

可选代理 `FLATNAS_PROXY_URL` 放在 `.secrets`。默认不挂载 Docker Socket，需要使用 FlatNas 的 Docker 管理功能时再设置 `FLATNAS_DOCKER_SOCKET=true`。首次登录请立即修改官方默认密码 `admin`。

安装：`sudo bash deploy.sh flatnas`；更新：`sudo bash deploy.sh flatnas update`。

详细说明：[flatnas/README.md](./flatnas/README.md)

### Sub2API

官方应用 + PostgreSQL + Redis 的独立 Compose 部署，Web 默认端口 `7010`，四项关键密钥首次安装自动生成并持久化；详细说明：[sub2api/README.md](./sub2api/README.md)。

安装：`sudo bash deploy.sh sub2api`；更新：`sudo bash deploy.sh sub2api update`。

### Mihomo · MetaCubeXD 官方完整版

Web + Agent + 自带 Mihomo 内核，一体化提供 Web 订阅 URL 导入、Profile/YAML 编辑和内核管理。默认代理 7011 只绑定本机；Web/Agent 是 7012 的根路径（不再是 /ui/）；内核 API 独立为 7013，通过原来的 MIHOMO_API_SECRET 认证。新增 MIHOMO_CONTROL_TOKEN 用于官方 Agent 控制，不是网页登录密码；管理界面需要可信网络/防火墙保护。不会启用 TUN、host、privileged 或 Docker Socket；[安全、端口、旧版迁移详见 Mihomo 说明](./mihomo/README.md)。

安装：sudo bash deploy.sh mihomo；更新：sudo bash deploy.sh mihomo update。旧 config.yaml 原样保留并备份、复制到新 Agent Profile（副本去除旧 external-ui-url）；完整版持久化目录 mihomo/data/all-in-one。内部 proxy-net 和 mihomo:7890 保留，其他容器可使用 sudo bash deploy.sh proxy connect / disconnect / status。已存在的完整版 Profile、密码和 active.yaml 不会被安装器覆盖。

### GitHub Actions self-hosted Runner

`.env`：

```dotenv
GITHUB_RUNNER_URL=https://github.com/<owner>/<repo>
GITHUB_RUNNER_NAME=
GITHUB_RUNNER_LABELS=
GITHUB_RUNNER_GROUP=
GITHUB_RUNNER_USER=github-runner
GITHUB_RUNNER_PROXY=
```

首次注册时在 `.secrets` 填写：

```dotenv
GITHUB_RUNNER_TOKEN=<registration-token>
```

安装：

```bash
sudo bash deploy.sh github-runner
```

注册成功后可以清空真实 `.secrets` 中的 `GITHUB_RUNNER_TOKEN`。

详细说明：[github-runner/README.md](./github-runner/README.md)

## 七、查看状态与日志

Docker 容器：

```bash
docker ps
```

常用日志：

```bash
docker logs -f frps
docker logs -f easytier
docker logs -f opencode
docker logs -f portainer
docker logs -f flatnas
docker logs -f sub2api
docker logs -f mihomo
```

GitHub Runner：

```bash
cd <SOFTWARE_ROOT>/github-runner/data/runner
sudo ./svc.sh status
```

EasyTier OpenWrt：

```bash
/etc/init.d/easytier status
logread -e easytier
easytier-cli -p 127.0.0.1:7006 node
```

## 八、常见问题

### Docker 找不到

如果出现：

```text
未检测到 Docker
```

先安装 Docker。

如果出现：

```text
未检测到 Docker Compose Plugin
```

确认下面命令可正常执行：

```bash
docker compose version
```

### 端口被占用

查看监听：

```bash
ss -lntup
```

再修改 `<SOFTWARE_ROOT>/deploy/.env` 对应端口。

FRPS 的代理端口还必须同步修改 `FRPS_PROXY_PORTS`。

### 配置新增后没有出现

拉取仓库后执行：

```bash
sudo bash deploy.sh env
```

脚本会从模板补充缺失配置项，并处理仓库内已定义的旧配置迁移。

### OpenCode build 代理

Docker build 中不要把宿主机代理写成：

```text
http://127.0.0.1:7890
```

推荐使用：

```dotenv
BUILD_HTTP_PROXY=http://host.docker.internal:7890
BUILD_HTTPS_PROXY=http://host.docker.internal:7890
```

同时要确保宿主机代理允许 Docker bridge 访问。

### EasyTier 出现 TUN 权限错误

fnOS / 某些 Linux 环境出现：

```text
rust tun error Operation not permitted
```

将：

```dotenv
EASYTIER_PRIVILEGED=true
```

然后重新部署 EasyTier。

## 九、安全说明

- 不要提交真实 `.env` / `.secrets`。
- 密码、Token、密钥只放 `.secrets`。
- `.env.example` / `.secrets.example` 只能放示例或占位值。
- EasyTier cloud 模式的 Core 也接入本机 Config Server；是否中继数据由 Web 下发的云端实例配置决定。
- `7007` 建议只对可信管理来源开放；`7008` 建议限制为需要接入的 Core 节点来源；`7006` RPC 只应本机访问。
- 如果要求云端只协调 P2P，必须在 Web 的云端实例中设置 `disable_relay_data=true`、`relay_all_peer_rpc=true`、`enable_exit_node=false`；不再由脚本强制保证。
- FRPS Dashboard 建议设置强密码并限制公网来源。
- Portainer 直接挂载 Docker Socket，管理入口应限制访问来源。
- Sub2API 的 PostgreSQL / Redis 不对外发布，管理员入口在公网须通过 HTTPS 和访问控制保护。
- MetaCubeXD 完整版：7011 代理仅宿主机回环；7012 Web/Agent 与 7013 内核 API 默认监听全部 IPv4 以便 NAS / EasyTier 管理；官方 CONTROL_TOKEN 会暴露给同源浏览器，不提供网页登录保护，必须通过防火墙或带认证的代理限制 Web 来源。内核 API 使用单独的 MIHOMO_API_SECRET。真实 .env/.secrets 不被模板覆盖。
- FlatNas 默认不挂载 Docker Socket；如需开启 Docker 管理，必须限制访问来源并修改默认管理密码。
- GitHub Runner 注册 Token 只在首次注册时使用，注册成功后可清空。

## 十、CI 检查

仓库包含：

```text
.github/workflows/shell-check.yml
.github/workflows/self-hosted-runner-check.yml
```

Shell Check 会在 Shell 脚本变化时执行：

```text
bash -n
ShellCheck --severity=error
```

Self-hosted Runner Check 可用于验证已注册 Runner 的运行环境。
