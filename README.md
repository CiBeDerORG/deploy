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

## 部署回答与维护规范

**全局强制规范**见 [AGENTS.md](./AGENTS.md)。以后**新增应用、更新安装脚本，或用户询问安装方式**，文档与回答都必须提供以下信息：

1. **配置文件及示例**：`<SOFTWARE_ROOT>/deploy/.env`（普通配置）、`<SOFTWARE_ROOT>/deploy/.secrets`（密码、Token 等敏感配置）的实际路径、完整示例、默认值、必填/可选项。
2. **配置与运行要求**：支持的系统/架构、Docker/Compose 或其他依赖、端口、防火墙及 HTTPS、磁盘挂载权限、必要的外部服务；只注明有依据的硬件最低要求。
3. **密码/密钥要求和自动生成机制**：每个凭据说明是否必填、能否留空自动生成、是否由上游生成、上游强制长度/字符/格式要求、生成后的安全保存位置和查看方法。**新应用的本地可生成凭据默认可留空，首次安装安全自动生成并持久化；再次安装或更新不重置。** 未知的密码限制不自行发明，外部平台签发的 OAuth/PAT 等不能假装能自动生成。
4. **安装命令**：拉取正确分支、`sudo bash deploy.sh env`、配置操作、完整安装命令及访问/验证方式。
5. **卸载命令**：提供真正可执行的卸载方法，区分仅移除服务与永久删除持久化数据，默认不删数据。
6. **更新命令**：提供更新步骤，明确是否保留数据和密钥。

默认 fnOS 配置目录为 `/vol3/1000/software/deploy/`；其他 Linux 默认 `/software/deploy/`。真实凭据严禁提交 Git，不应在标准日志或回答里明文打印。Windows `deploy.ps1` 与 Linux `deploy.sh` 是不同入口，只有已经实现的功能才能给出对应命令。

目前 `uninstall` 仅适用于已提供 `deploy/uninstall.sh` 的业务与专用原生桌面项目，不能假定所有历史服务均支持统一卸载。

## Windows 11 原生部署（PowerShell）

Windows 11 使用根目录的 `deploy.ps1`，直接调用 Windows 上的 Docker CLI / Docker Compose；不会启动 WSL Bash，也不会执行仓库中的 `.sh` 安装脚本。Linux / fnOS 仍使用原有 `deploy.sh`，两套入口互不替换。

在 PowerShell 中执行：

```powershell
.\deploy.ps1 list
.\deploy.ps1 env
```

首次执行 `env` 后，编辑以下 Windows 专用配置文件：

```text
%LOCALAPPDATA%\CiBeDerORG\deploy\software\deploy\.env
%LOCALAPPDATA%\CiBeDerORG\deploy\software\deploy\.secrets
```

配置完成后，例如：

```powershell
.\deploy.ps1 portainer
.\deploy.ps1 flatnas
.\deploy.ps1 sub2api
.\deploy.ps1 qoder2api-hub
.\deploy.ps1 mihomo update
```

默认软件根目录为 `%LOCALAPPDATA%\CiBeDerORG\deploy\software`，可通过当前 PowerShell 会话的 `$env:SOFTWARE_ROOT` 指定其他路径。若执行策略阻止脚本，可使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 list
```

注意：

- 需要已启动的 Docker Desktop 和 Docker Compose v2。
- Windows 配置与数据目录和 Linux 默认的 `/software` 分开，避免误用 Linux 路径或覆盖另一套配置。
- Linux systemd 服务、OpenWrt 原生安装以及 `mihomo host`、`fnos-desktop` 不由 Windows PowerShell 入口执行。
- EasyTier / 手机执行器依赖 Linux host networking、TUN 或设备网络能力；Docker Desktop 上的兼容性与 Linux 主机不同，部署前需确认相应功能可用。

## 服务一览

| 服务 | 默认端口 / 入口 | 部署方式 | 详细文档 |
| --- | --- | --- | --- |
| fnOS Desktop（宿主机原生） | `7015/HTTPS`（noVNC） | **apt + systemd（不使用 Docker）** | [fnos-desktop/README.md](./fnos-desktop/README.md) |
| LinuxServer Webtop | `7014/HTTPS` | Docker Compose（Debian XFCE / Selkies） | [webtop/README.md](./webtop/README.md) |
| OpenHands Agent Canvas | `7016/HTTP`（`/canvas`） | Docker Compose（官方 GHCR 镜像） | [openhands/README.md](./openhands/README.md) |
| EasyNetTopo | `7017/HTTP`（监听 IP 可配置） | 单容器 Docker Compose，支持 GHCR 镜像轮换 | [部署与首次登录](./easynettopo/README.md) |
| EasyHostAgent | `7018/HTTP 或 HTTPS`（可配置） | Linux/fnOS 单容器 Docker Compose，GitHub Actions 构建 GHCR AMD64/ARM64 镜像 | [镜像部署说明](./easyhostagent/README.md) |
| OpenCode V2 | `7003/TCP` | Docker Compose | [opencode/README.md](./opencode/README.md) |
| FRPS | `7000/TCP`，后台 `7001/TCP` | Docker Compose | [frps/README.md](./frps/README.md) |
| EasyTier | Core `7005`，RPC `7006`，Web `7007`，Config `7008/UDP` | Docker / OpenWrt | [easytier/README.md](./easytier/README.md) |
| EasyTier 手机执行器 | `8766/TCP`（默认仅本机监听） | 独立 Docker Compose，Linux amd64 | [easytier-automation-executor/README.md](./easytier-automation-executor/README.md) |
| Portainer CE | `7004/TCP` | Docker Compose | [portainer/README.md](./portainer/README.md) |
| FlatNas | `7009/TCP` | Docker Compose | [flatnas/README.md](./flatnas/README.md) |
| Sub2API | `7010/TCP` | Docker Compose（含 PostgreSQL、Redis） | [sub2api/README.md](./sub2api/README.md) |
| Qoder2API Hub | `8790/TCP`（默认仅本机监听） | Docker Compose（官方 AMD64 / ARM64 镜像） | [qoder2api-hub/README.md](./qoder2api-hub/README.md) |
| Mihomo / MetaCubeXD 完整版 | 代理 `7011/TCP`（宿主机）、Web/Agent `7012/TCP`、内核 API `7013/TCP` | Docker Compose **或原生 systemd** | [mihomo/README.md](./mihomo/README.md) |
| GitHub Actions Runner | 无固定 Web 端口 | systemd | [github-runner/README.md](./github-runner/README.md) |

## 一、运行环境

Docker 服务需要：

- Linux / fnOS
- Bash
- root 或 sudo 权限
- Docker
- Docker Compose v2 Plugin（命令为 `docker compose`）
- 启用镜像加速且部署涉及 GHCR 镜像时需要 `flock`（通常由 util-linux 提供），用于并发保护轮换记录

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
sudo bash deploy.sh openhands
sudo bash deploy.sh frps
sudo bash deploy.sh easytier
sudo bash deploy.sh easytier-automation-executor
sudo bash deploy.sh portainer
sudo bash deploy.sh flatnas
sudo bash deploy.sh sub2api
sudo bash deploy.sh qoder2api-hub
sudo bash deploy.sh webtop
# fnOS 宿主机原生 XFCE4（会安装系统软件包；不需 Docker）
sudo bash deploy.sh fnos-desktop
sudo bash deploy.sh mihomo
# 可选：Mihomo 无 Docker 的完整 Web/Agent/内核原生安装
sudo bash deploy.sh mihomo host
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
sudo bash deploy.sh openhands uninstall
sudo bash deploy.sh mihomo host
sudo bash deploy.sh mihomo host-update
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
| `deploy.sh <服务> uninstall` | 仅支持已提供标准卸载脚本的应用；通常仅移除容器，持久化数据默认保留 |
| `deploy.sh mihomo host/host-update` | 选择原生安装/升级 Mihomo 一体化 Web + Agent + Core（不调用 Docker） |
| `deploy.sh proxy connect/disconnect <容器名>` | 动态接入/断开 Mihomo 的 proxy-net 内部共享网络，不修改业务 Compose |
| `deploy.sh proxy status [容器名]` | 查看共享网络成员或单容器接入状态 |

## 四、目录结构

典型运行目录：

```text
<SOFTWARE_ROOT>/
├── deploy/
│   ├── .env
│   ├── .secrets
│   ├── lib/image-sources.sh
│   └── state/image-mirror.last
├── openhands/
│   ├── data/ workspace/
│   └── deploy/
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
├── easytier-automation-executor/
│   ├── data/runtime/ data/adb/
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

### 全局镜像源与轮换

在统一 `<SOFTWARE_ROOT>/deploy/.env` 中配置：

```dotenv
# 只对 ghcr.io 镜像生效；original 使用原始镜像，mirror 使用加速镜像。
# 可选，默认 original；Docker Hub、MCR 等其他来源始终保留原地址。
DOCKER_IMAGE_SOURCE=mirror
# 可选，按逗号分隔的顺序轮换；空值或未配置时使用以下默认值。
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
```

这是 deploy 自身提供的配置，所有 Docker 部署项目共用同一条判断规则：**只有原始仓库为 `ghcr.io` 的镜像才转换到加速站**。其他镜像地址完整保留，不参与轮换。目前各项目的效果如下：

| 项目 | 镜像来源与处理方式 |
| --- | --- |
| EasyTier | 默认 GHCR 镜像会加速；`EASYTIER_IMAGE` 指定非 GHCR 镜像时保留原地址，cloud / intranet 共用 |
| EasyTier 手机执行器 | 独立 `EASYTIER_EXECUTOR_IMAGE`，仅原始 GHCR 镜像参与同一全局轮换，不触发主服务更新 |
| FRPS | GHCR 服务镜像会加速 |
| Mihomo Docker | GHCR 完整版镜像会加速；启动前检查和 Compose 共用本轮镜像 |
| FlatNas | 当前为 Docker Hub 镜像，原样使用 |
| Portainer | 当前为 Docker Hub 镜像，原样使用 |
| Sub2API | 应用、PostgreSQL、Redis 当前均为 Docker Hub 镜像，三个地址均原样使用 |
| OpenHands Agent Canvas | 官方 GHCR 镜像参与统一镜像源轮换 |
| OpenCode | MCR 基础镜像原样使用；构建输出仍为 `opencode-local:latest` |

轮换规则：

- 每次包含 GHCR 镜像的 Docker 安装或更新选择一个加速站，同一次执行的 GHCR 镜像拉取、检查、构建和启动共用该站。
- 所有项目共用 `<SOFTWARE_ROOT>/deploy/state/image-mirror.last`，按配置顺序循环。例如默认顺序下，先执行 `easytier update` 使用 DockerProxy，再执行 `mihomo update` 使用 GH-Proxy，下一次包含 GHCR 镜像的部署使用 DockerProxy；中间执行 `sub2api update` 不推进轮换。
- 完成业务预检并选站后，在 Compose 校验、拉取或构建之前记录本轮位置；后续校验或拉取失败，再次执行脚本也会从下一个站开始，不在一次执行中自动重试其他站。
- 使用文件锁和原子替换保存记录，避免两个部署进程同时覆盖轮换位置。更改列表后，如果上次站点仍在列表中，就从它后面继续；否则从第一项开始。
- `original` 模式、没有 GHCR 镜像的部署、`env`、`list`、`sync`、代理网络管理不推进轮换。GitHub Runner、Mihomo 原生模式、EasyTier OpenWrt 使用原生安装流程，也不推进镜像轮换。
- 同一次部署混用 GHCR 与其他仓库时，仅转换 GHCR 镜像，其余镜像原样使用。识别按仓库域名进行，路径中包含 `ghcr.io` 或 `ghcr.io.example.com` 这样的其他域名不会误判为 GHCR。

配置中的原始镜像始终保留。例如 EasyTier 继续填写：

```dotenv
EASYTIER_IMAGE=ghcr.io/cibederorg/easytier:feat-node-attributes-main
```

本轮选中 DockerProxy 时，脚本仅在当前执行环境中使用：

```text
ghcr.dockerproxy.net/cibederorg/easytier:feat-node-attributes-main
```

GHCR 镜像的组织、嵌套路径、标签和 digest 会保留。已知 GHCR 专用加速域名，以及 `m.daocloud.io/ghcr.io/...`、`gh-proxy.com/docker/ghcr.io/...`，会先还原到 `ghcr.io` 再转换，防止重复加前缀；切回 `original` 也会还原这些已识别的 GHCR 地址。Docker Hub 短名称、MCR、自定义仓库及非 GHCR 加速地址均按输入原样保留。

内置站点及限制（文档核对日期：2026-10-23）：

| 配置值 | GHCR 转换规则与限制 |
| --- | --- |
| `dockerproxy` | 默认候选。`ghcr.io/路径` 转为 `ghcr.dockerproxy.net/路径`。见 [官方文档](https://dockerproxy.net/docs)。 |
| `ghproxy` | 默认候选。`ghcr.io/路径` 转为 `gh-proxy.com/docker/ghcr.io/路径`，该站说明仅支持公开镜像。见 [Docker 代理文档](https://gh-proxy.com/docs/docker-mirror)。 |
| `nju` | 可选。`ghcr.io/路径` 转为 `ghcr.nju.edu.cn/路径`。见 [官方 GHCR 文档](https://doc.nju.edu.cn/books/e1654/page/ghcr)。 |
| `1ms` | 可选。`ghcr.io/路径` 转为 `ghcr.1ms.run/路径`，GHCR 有免费共享通道。见 [镜像列表](https://mdoc.cc/mliev/1ms/v1.0.0/3)。 |
| `daocloud` | 可选。`ghcr.io/路径` 转为 `m.daocloud.io/ghcr.io/路径`，需要镜像已在服务方白名单内；自建仓库未必获准。见 [官方说明与白名单](https://github.com/DaoCloud/public-image-mirror)。 |

默认列表为 `dockerproxy,ghproxy`，需要其他站点时自行修改顺序。公开服务的连通性与速度以部署机器实际拉取为准，白名单及服务方访问限制仍然适用。

更新使用方式：

```bash
git pull
sudo bash deploy.sh env
# 编辑统一 .env，将 DOCKER_IMAGE_SOURCE 改成 mirror
sudo bash deploy.sh easytier update
```

其余项目使用各自的 install/update 命令即可。根 `deploy.sh` 同步业务时，也会把公共模块同步到 `<SOFTWARE_ROOT>/deploy/lib/`；之后直接运行该业务的 `deploy/install.sh` 或 `deploy/update.sh` 同样生效。直接手动运行 `docker compose` 不会执行轮换逻辑，正常部署请使用上述脚本。

此配置只控制 GHCR 容器镜像地址，不负责 npm、Git、Release 下载等其他网络请求；Docker 构建内的 HTTP 代理继续使用原有 `BUILD_HTTP_PROXY` / `BUILD_HTTPS_PROXY` 配置。

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

默认 Docker 镜像为 `ghcr.io/cibederorg/easytier:feat-node-attributes-main`，支持 amd64 / arm64 匿名拉取。同一个容器部署两种角色：

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
EASYTIER_IMAGE=ghcr.io/cibederorg/easytier:feat-node-attributes-main
EASYTIER_ROLE=cloud
EASYTIER_HOSTNAME=easytier
EASYTIER_PRIVILEGED=false
EASYTIER_WEB_ENABLE_REGISTRATION=true
EASYTIER_WEB_API_HOST=http://<公网IP>:7007
EASYTIER_CONFIG_SERVER=
```

`EASYTIER_IMAGE` 是可选的 Docker 镜像配置，cloud / intranet 共用；留空或未配置时使用上述默认镜像。在统一 `.env` 修改完整镜像地址（支持标签或 digest）后执行 `sudo bash deploy.sh easytier update`，即可拉取指定镜像并重建容器，无需修改 Compose。执行 `sudo bash deploy.sh env` 会补齐缺失项并保留已有镜像值。自定义镜像的兼容要求见 [Docker 镜像](./easytier/README.md#docker-镜像)。

`EASYTIER_HOSTNAME` 是可选的容器主机名配置，cloud / intranet 均适用；默认、留空或未配置时使用 `easytier`。例如可在统一 `.env` 中设置 `EASYTIER_HOSTNAME=fnos`，更新服务后生效，无需修改 Compose 文件。详见 [容器主机名](./easytier/README.md#容器主机名)。

`EASYTIER_WEB_ENABLE_REGISTRATION` 是可选的部署配置：`true` 允许 Web 自助注册，`false` 禁止；默认、留空或未配置均为 `true`，已有账号仍可登录，仅 cloud 模式使用。拉取仓库后执行 `sudo bash deploy.sh env` 会把缺失的配置项补入 `<SOFTWARE_ROOT>/deploy/.env`；修改后执行 `sudo bash deploy.sh easytier update` 生效。当前镜像关闭注册后由后端拒绝注册请求，前端注册入口仍可能显示，详见 [注册开关说明](./easytier/README.md#web-注册开关)。

cloud Core 自动连接 `udp://127.0.0.1:7008/admin`。云端的**网络名称、网络密钥、虚拟 IPv4、Listener 和安全 flags 均在 Web 管理页面配置**，不再要求 `.env/.secrets` 提前填写网络身份。

进入云端 `7007` 页面，在对应机器新建网络实例，按照原组网填写网络名、密钥、IPv4（例如 `10.10.10.1/24`），并设置 `7005/TCP+UDP` 两个 Listener。

**重要：** 云端 Core 由 Web 接管后，原来静态 `cloud.toml` 所强制的 no-relay 限制不再存在。若不希望云端中继业务流量，必须在 Web **云端实例**的高级配置中设置 `disable_relay_data=true`、`relay_all_peer_rpc=true`、`enable_exit_node=false`；Web 可以再次修改这些设置，部署脚本无法强制锁定。

从旧版静态云端模式升级之前应备份 `/software/easytier/data/`。旧 `data/cloud-core/cloud.toml` 不再自动加载，也不会自动导入 Web；升级后需在 Web 中重新创建原有云端网络，期间云端 Peer 可能短暂不可用。

内网 `.env`：

```dotenv
EASYTIER_IMAGE=ghcr.io/cibederorg/easytier:feat-node-attributes-main
EASYTIER_ROLE=intranet
EASYTIER_HOSTNAME=easytier
EASYTIER_PRIVILEGED=true
EASYTIER_CONFIG_SERVER=udp://<公网服务器IP>:7008/admin
```

详细说明（含 Web、升级、OpenWrt）：[easytier/README.md](./easytier/README.md)

### EasyTier 手机执行器（独立）

使用单独 `ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center` 镜像，只支持 Linux amd64；默认 8766 只监听 127.0.0.1。需要在统一 `.env` 设置实际主服务回调地址 `EASYTIER_EXECUTOR_CALLBACK_URL`，跨主机使用时另设置可信私网监听 `EASYTIER_EXECUTOR_BIND_IP`；令牌 `EASYTIER_EXECUTOR_TOKEN` 只保存在统一 `.secrets`，首次留空由安装脚本生成。数据及 ADB 密钥保留在 `<SOFTWARE_ROOT>/easytier-automation-executor/data/`。

安装：`sudo bash deploy.sh easytier-automation-executor`；更新：`sudo bash deploy.sh easytier-automation-executor update`。执行器安装后还需在 EasyTier 管理员「自动化中心 → 设置」录入执行器地址和同一 Token。详细说明：[独立执行器](./easytier-automation-executor/README.md)。

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

Docker 安装：`sudo bash deploy.sh mihomo`；Docker 更新：`sudo bash deploy.sh mihomo update`。

新增原生安装：`sudo bash deploy.sh mihomo host`；原生更新：`sudo bash deploy.sh mihomo host-update`。原生方式无需 Docker，使用 `deploy-mihomo.service` 管理完整 MetaCubeXD Web/Agent/内核，继续读取相同的 `.env`、`.secrets`、`mihomo/data/all-in-one`；默认 Docker 命令、容器和 Compose 不变。两个模式不能同时运行；切换前须自行停止另一种方式。详细见 [Mihomo 原生安装与切换说明](./mihomo/README.md)。旧 config.yaml 原样保留并备份、复制到新 Agent Profile（副本去除旧 external-ui-url）；完整版持久化目录 mihomo/data/all-in-one。内部 proxy-net 和 mihomo:7890 保留，其他容器可使用 sudo bash deploy.sh proxy connect / disconnect / status。已存在的完整版 Profile、密码和 active.yaml 不会被安装器覆盖。

fnOS 保持全局 `SOFTWARE_ROOT=/vol3/1000/software`，Mihomo 的运行数据与配置集中在
`/vol3/1000/software/mihomo/`；原生程序、缓存、临时文件、升级事务备份和日志都在其
`runtime/host/` 子目录。统一 `.env` / `.secrets` 仍放在 `/vol3/1000/software/deploy/`，
本次原生修复不新增配置项。systemd 必需的开机注册文件由模块内配置生成，等待数据盘挂载后启动。
具体目录和失败恢复行为见 [Mihomo fnOS 目录说明](./mihomo/README.md#fnos-目录与配置位置)。

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

### EasyHostAgent · 原生主机执行器

使用 GitHub Actions 构建并发布的 Linux AMD64/ARM64 GHCR 镜像，由 Docker Compose 直接拉取部署，不需要宿主机编译 Go。普通配置统一写入 `.env`：

```dotenv
EASYHOSTAGENT_IMAGE=ghcr.io/cibederorg/easyhostagent:feat-docker-app-store
EASYHOSTAGENT_TRANSPORT=https
EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018
EASYHOSTAGENT_DATA_DIR=/var/lib/easyhostagent
EASYHOSTAGENT_SOFTWARE_ROOT=
EASYHOSTAGENT_APP_GRANTS=
```

执行 `sudo bash deploy.sh easyhostagent install`、`sudo bash deploy.sh easyhostagent update`、`sudo bash deploy.sh easyhostagent uninstall`。只有按需安装、卸载、状态查询，没有心跳；需要在可信网络使用 HTTP 时将 `EASYHOSTAGENT_TRANSPORT=http`，并限制防火墙访问。卸载只移除 Agent 容器，保留身份、配对、应用数据和其他 Docker 应用。详见 [EasyHostAgent 安装与配置](./easyhostagent/README.md)。

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
- Qoder2API Hub 默认只绑定本机；如改为局域网监听，必须先修改上游默认面板密码 admin，并通过防火墙限制来源。API Key 留空时由上游首次启动生成，保存在持久化账号目录。
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
