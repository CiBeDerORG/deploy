# EasyHostAgent · 原生部署（Linux / fnOS）

EasyHostAgent 是直接运行在宿主机上的 Go systemd 服务，不是 Docker 容器。EasyNetTopo 主动通过 HTTP 或 HTTPS 调用应用安装、卸载、状态查询接口，**不需要心跳**。本模块复用 upstream 原生安装器，直接从 GitHub Release 下载对应 CPU 的二进制，并校验 SHA-256，不在目标机器本地构建。

## 1. 配置文件

所有普通配置在统一的 `<SOFTWARE_ROOT>/deploy/.env`。Ubuntu 默认 `/software/deploy/.env`，fnOS 默认 `/vol3/1000/software/deploy/.env`。敏感配置文件分别是 `/software/deploy/.secrets` 或 `/vol3/1000/software/deploy/.secrets`，但 **Agent 不需要新增密码、API Key 或 Token 配置项**；配对凭据由上游在本机生成和保存。

运行 `sudo bash deploy.sh env` 后用 `sudoedit /software/deploy/.env`（fnOS 修改相应路径），设置：

```dotenv
# GitHub Actions 构建的开发版 Release，发布包附有 SHA-256。
EASYHOSTAGENT_RELEASE=v0.1.0-appstore.dev
# 可选，手动上传时填写绝对路径；留空从 GitHub Release 下载。
EASYHOSTAGENT_LOCAL_BINARY=
# 可改为 http；HTTP 明文不适合公网。
EASYHOSTAGENT_TRANSPORT=https
EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018
EASYHOSTAGENT_LOG_LEVEL=info
EASYHOSTAGENT_DATA_DIR=/var/lib/easyhostagent
# 留空时使用统一 SOFTWARE_ROOT。
EASYHOSTAGENT_SOFTWARE_ROOT=
# 可选：控制端UUID/来源UUID，多个以逗号分隔。
EASYHOSTAGENT_APP_GRANTS=
```

若服务器无法连接 GitHub，可把对应架构的两个文件上传到同一目录，例如 `/software/easyhostagent/easyhostagent-linux-amd64` 和 `/software/easyhostagent/easyhostagent-linux-amd64.sha256`，随后设置 `EASYHOSTAGENT_LOCAL_BINARY=/software/easyhostagent/easyhostagent-linux-amd64`。安装脚本在安装前校验 SHA-256；上传的文件保留原样，不需要手工更改可执行权限。留空仍按 `EASYHOSTAGENT_RELEASE` 下载。两种模式统一使用 `sudo bash deploy.sh easyhostagent install` 和 `update`。**本地文件及同名校验文件必须来自可信 GitHub Release。**

安装后将配置同步到 `/etc/easyhostagent/agent.env`，保留其中其他非托管配置项。安装、更新不会重置 Agent 身份、配对授权或已有应用状态。开发版 `v0.1.0-appstore.dev` 是**发布资产可更新的滚动标签**；生产机器建议改为明确、不可变的正式版本号。相应的 AMD64 / ARM64 二进制、同名 `.sha256` 均由 GitHub Actions 生成。

## 2. 运行条件和网络

- 系统：Linux / fnOS，systemd 作为 init；CPU：AMD64 或 ARM64。
- 安装依赖：root、Bash、curl、sha256sum、install、mktemp、flock、systemctl；运行 Docker 应用管理功能还需本机可用的 Docker Engine。
- 监听：默认 `0.0.0.0:7018`，开放范围由防火墙限制。只有在信任隔离网络并配置访问来源限制时才改 `EASYHOSTAGENT_TRANSPORT=http`；HTTP 明文会暴露一次性配对码、Bearer Token 和操作参数，严禁未经保护直接对公网开放。HTTPS 使用 Agent 的自签名证书及 EasyNetTopo 的固定公钥指纹校验。
- 进程以 root 运行以便操作本机 Docker；数据默认在 `/var/lib/easyhostagent`（系统安装器保留），受管应用在 `<SOFTWARE_ROOT>/.easyhostagent-apps/`。
- Agent 无主动心跳、无定时上报；状态按需查询。未提供强制 CPU/RAM 最小值。

## 3. 凭据与应用授权

无需输入管理员密码。Agent 首次启动在数据目录生成自身 UUID 和 TLS 身份；在 Agent 所在机器可信终端查看：

```bash
sudo /usr/local/bin/easyhostagent -identity
sudo /usr/local/bin/easyhostagent -pairing-code
```

配对码是**本机按需自动生成**的临时凭据，配对成功后的控制端 Token 由 Agent 签发并保存在控制端和 Agent 各自的受保护状态中；它们**不在**统一 `.secrets` 中填写，也不应放进命令参数或聊天记录。配对完成后，在 EasyNetTopo 中获得控制端 UUID 与 Git 来源 UUID，将 `EASYHOSTAGENT_APP_GRANTS` 设置为 `控制端UUID/来源UUID`，执行更新来应用授权。未授权时可查询应用状态，但无法安装/卸载来源应用。

## 4. 安装和检查

```bash
cd /software/deploy
git switch feat/docker-app-store
git pull --ff-only origin feat/docker-app-store
sudo bash deploy.sh env
sudo bash deploy.sh easyhostagent install

sudo systemctl status easyhostagent --no-pager
sudo journalctl -u easyhostagent -n 40 --no-pager
```

fnOS 在其实际 deploy 仓库目录执行相同相对命令。安装前用 `sudoedit` 按第 1 节配置统一 `.env`。HTTP 模式且监听回环或所有网卡时：

```bash
curl -fsS http://127.0.0.1:7018/v1/health
```

HTTPS 自签名模式的**仅用于无凭据健康诊断**的命令：

```bash
curl -kfsS https://127.0.0.1:7018/v1/health
```

`-k` 不能用于控制端配对、令牌操作或实际管理通信。EasyNetTopo 中添加主机时填写 `http://设备IP:7018`（HTTP）或 `设备IP:7018` / `https://设备IP:7018`（HTTPS）。

## 5. 卸载（保留数据）

```bash
sudo bash deploy.sh easyhostagent uninstall
```

只卸载本项目标记管理的 systemd 服务和 `/usr/local/bin/easyhostagent`，保留 `/etc/easyhostagent/agent.env`、`/var/lib/easyhostagent`、可能自定义的数据目录、身份和配对状态、受管 Docker 应用及卷、统一 `.env` 和 `.secrets`。**无隐式数据清除操作**；如需永久删除须单独人工确认。

## 6. 更新

```bash
cd /software/deploy
git pull --ff-only origin feat/docker-app-store
sudo bash deploy.sh easyhostagent update
```

更新时按 `EASYHOSTAGENT_LOCAL_BINARY` 选择使用本地包或 GitHub Release，并验证 SHA-256 后替换二进制，再同步 Agent 配置项并重启 systemd；现有身份、配对凭据、应用目录和 Docker 容器保留。更新过程中如发生下载或校验错误，官方原生安装器会在替换二进制前退出。已存在由其他安装器管理的同名服务时会拒绝接管。如果此前已安装 EasyHostAgent Docker 容器，须先安全停止并移除该旧容器；新安装器会检测同名容器并拒绝同时运行，避免两个 Agent 共用端口与身份数据。
