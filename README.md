# deploy

统一管理 Linux / fnOS 上的服务部署。仓库可以放在任意目录，真正的运行文件统一同步到 `<SOFTWARE_ROOT>/<服务名>`。

## 配置文件

全局配置拆成两个真实文件：

```text
<SOFTWARE_ROOT>/deploy/.env
<SOFTWARE_ROOT>/deploy/.secrets
```

- `.env`：路径、端口、地址、角色、开关等普通配置。
- `.secrets`：账号、密码、Token、密钥等敏感配置。
- 仓库中的 `.env.example` 与 `.secrets.example` 仅作为模板。
- 两个真实文件统一设置为 `root:root 0600`。
- 真实 `.env` 和 `.secrets` 已加入 Git 忽略规则，不应提交到仓库。

初始化或同步配置：

```bash
sudo bash deploy.sh env
```

首次运行会创建缺失的真实配置。从旧版本升级时，`deploy.sh env` 会把已知敏感变量从旧 `.env` 迁移到 `.secrets`。

### 配置解析规则

各服务安装脚本不再使用 Bash `source` 执行 `.env` 或 `.secrets`，而是只按 `KEY=VALUE` 读取并导出变量。

因此密码、Token 中的特殊字符不会作为 Shell 代码执行，例如：

```dotenv
PASSWORD=abc$123&x#y
TOKEN='abc$123&x#y'
OTHER="a value with spaces"
```

解析规则：

- 空行和以 `#` 开头的整行注释会忽略。
- 变量名必须符合 `[A-Za-z_][A-Za-z0-9_]*`。
- 最外层成对的单引号或双引号会移除。
- 引号内部和普通值中的变量引用、命令替换、反引号、`$`、`&` 等全部按字面值处理，不执行、不展开。
- 不支持 `export KEY=VALUE`，请直接使用 `KEY=VALUE`。

安装脚本加载两个文件后，通过进程环境把变量传给 Docker Compose，不再让 Compose 使用 `--env-file` 二次解析敏感值。

## SOFTWARE_ROOT

Ubuntu 默认：

```dotenv
SOFTWARE_ROOT=/software
```

fnOS 默认：

```dotenv
SOFTWARE_ROOT=/vol3/1000/software
```

运行后的目录结构：

```text
<SOFTWARE_ROOT>/
├── deploy/
│   ├── .env
│   └── .secrets
├── opencode/
├── frps/
├── easytier/
├── portainer/
└── github-runner/
```

## deploy.sh

常用命令：

```bash
bash deploy.sh --help
bash deploy.sh list
sudo bash deploy.sh env

sudo bash deploy.sh <服务名>
sudo bash deploy.sh <服务名> install
sudo bash deploy.sh <服务名> update
sudo bash deploy.sh <服务名> sync
```

当前服务：

| 服务 | 安装命令 | 运行目录 |
| --- | --- | --- |
| OpenCode | `sudo bash deploy.sh opencode` | `<SOFTWARE_ROOT>/opencode` |
| FRPS | `sudo bash deploy.sh frps` | `<SOFTWARE_ROOT>/frps` |
| EasyTier | `sudo bash deploy.sh easytier` | `<SOFTWARE_ROOT>/easytier` |
| Portainer | `sudo bash deploy.sh portainer` | `<SOFTWARE_ROOT>/portainer` |
| GitHub Runner | `sudo bash deploy.sh github-runner` | `<SOFTWARE_ROOT>/github-runner` |

根 `deploy.sh` 会把服务目录同步到 `<SOFTWARE_ROOT>/<服务名>`，同时保留：

```text
deploy/.env
deploy/.secrets
data/
state/
workspace/
backup/
```

## 主要环境变量

普通配置位于 `.env`：

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
```

敏感配置位于 `.secrets`：

```dotenv
OPENCODE_SERVER_PASSWORD=

FRPS_DASHBOARD_USER=admin
FRPS_DASHBOARD_PASSWORD=

PORTAINER_ADMIN_PASSWORD=

GITHUB_RUNNER_TOKEN=
```

## FRPS

普通配置：

```dotenv
FRPS_BIND_PORT=7000
FRPS_DASHBOARD_PORT=7001
FRPS_PROXY_PORTS='["3389","7100-7800"]'
```

敏感配置：

```dotenv
FRPS_DASHBOARD_USER=admin
FRPS_DASHBOARD_PASSWORD=
```

`FRPS_PROXY_PORTS` 支持单端口和连续范围。安装脚本会同步生成：

- `frps/config/frps.toml` 中的 `allowPorts`
- `frps/deploy/docker-compose.yaml` 中的 Docker 端口映射

固定 vhost 映射：

```text
9080 -> 80
9443 -> 443
```

只重新生成 FRPS 配置、不启动容器：

```bash
bash <SOFTWARE_ROOT>/frps/deploy/install.sh apply-config
```

## OpenCode

普通配置：

```dotenv
OPENCODE_PORT=7003
MYAI_IP=203.0.113.10
BUILD_NO_PROXY=127.0.0.1,localhost
```

如果需要 Docker build 代理，可在真实 `.env` 中增加：

```dotenv
BUILD_HTTP_PROXY=http://172.17.0.1:7890
BUILD_HTTPS_PROXY=http://172.17.0.1:7890
```

敏感配置：

```dotenv
OPENCODE_SERVER_PASSWORD=
```

安装 / 更新：

```bash
sudo bash deploy.sh opencode
sudo bash deploy.sh opencode update
```

## EasyTier

Docker 部署使用一个容器，通过 `EASYTIER_ROLE` 区分公网端和内网端。

统一端口：

```dotenv
EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_WEB_PORT=7007
EASYTIER_CONFIG_PORT=7008
```

| 变量 | 用途 |
| --- | --- |
| `EASYTIER_PORT` | EasyTier Core TCP/UDP Listener |
| `EASYTIER_RPC_PORT` | 本机 Core RPC |
| `EASYTIER_WEB_PORT` | Web Console |
| `EASYTIER_CONFIG_PORT` | Web Config Server |

### cloud 公网端

```dotenv
EASYTIER_ROLE=cloud
EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_WEB_PORT=7007
EASYTIER_CONFIG_PORT=7008
EASYTIER_PRIVILEGED=false
EASYTIER_WEB_API_HOST=http://<公网或管理地址>:7007
EASYTIER_CONFIG_SERVER=
```

cloud 模式在同一个容器中同时运行：

```text
easytier-web-embed
easytier-core
```

本机 Core 使用本机 Config Server：

```text
udp://127.0.0.1:7008/admin
```

### intranet 内网端

```dotenv
EASYTIER_ROLE=intranet
EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_PRIVILEGED=true
EASYTIER_CONFIG_SERVER=udp://<公网服务器IP>:7008/admin
```

intranet 模式只运行 `easytier-core`，从公网 Web Config Server 接收配置；`EASYTIER_WEB_API_HOST` 在该角色下不使用。

网络名、网络密钥、虚拟 IP / DHCP、Peer、Private Mode、子网代理等继续在 EasyTier Web Console 中管理。

当前废弃变量：

```text
EASYTIER_MODE
EASYTIER_PEERS
EASYTIER_NETWORK_NAME
EASYTIER_NETWORK_SECRET
```

`EASYTIER_PORT` 和 `EASYTIER_RPC_PORT` 当前仍在使用，并不是废弃变量。

OpenWrt 使用独立安装脚本：

```text
easytier/openwrt/install.sh
```

示例：

```bash
sh install.sh --config-server udp://<公网服务器IP>:7008/admin
```

详细说明见 `easytier/README.md`。

## Portainer

普通配置：

```dotenv
PORTAINER_HTTP_PORT=7004
PORTAINER_EDGE_PORT=8000
PORTAINER_EDGE_CONTAINER_PORT=8000
```

敏感配置：

```dotenv
PORTAINER_ADMIN_PASSWORD=
```

管理员密码至少需要 12 个字符。

## GitHub Actions self-hosted Runner

普通配置：

```dotenv
GITHUB_RUNNER_URL=https://github.com/<owner>/<repo>
GITHUB_RUNNER_NAME=
GITHUB_RUNNER_LABELS=
GITHUB_RUNNER_GROUP=
GITHUB_RUNNER_USER=github-runner
GITHUB_RUNNER_PROXY=
```

Runner 版本固定为 `latest`，工作目录固定为 `_work`，无需写入 `.env`。

如果服务器访问 GitHub 较慢，可只给 Runner 下载配置代理：

```dotenv
GITHUB_RUNNER_PROXY=http://127.0.0.1:7890
```

也支持例如 `socks5h://127.0.0.1:7890`。该代理只用于 Runner 安装脚本访问 GitHub API 和下载 Runner，不设置全局 `HTTP_PROXY` / `HTTPS_PROXY`。

首次注册时在 `.secrets` 中填写：

```dotenv
GITHUB_RUNNER_TOKEN=<registration-token>
```

安装：

```bash
sudo bash deploy.sh github-runner
```

注册成功后，`GITHUB_RUNNER_TOKEN` 可以从真实 `.secrets` 清空。

详细说明见 `github-runner/README.md`。

## 更新与日志

更新仓库和指定服务：

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh <服务名> update
```

查看容器：

```bash
docker ps
```

查看日志不需要手工读取 `.env` / `.secrets`：

```bash
docker logs -f frps
docker logs -f easytier
docker logs -f opencode
docker logs -f portainer
```

GitHub Runner 状态：

```bash
cd <SOFTWARE_ROOT>/github-runner/data/runner
sudo ./svc.sh status
```

## Shell 检查

仓库的 `.github/workflows/shell-check.yml` 会在 Shell 脚本变化时执行：

```text
bash -n
ShellCheck --severity=error
```
