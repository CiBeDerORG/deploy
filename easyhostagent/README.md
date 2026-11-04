# EasyHostAgent · 原生部署（Linux / fnOS）

EasyHostAgent 是直接运行在宿主机上的 Go systemd 服务，不是 Docker 容器。EasyNetTopo 主动通过 HTTP 或 HTTPS 调用应用安装、卸载、状态查询接口，**不需要心跳**。本模块复用 upstream 原生安装器，由 deploy 公共下载模块获取 GitHub Release 对应 CPU 的二进制并验证 SHA-256，不在目标机器本地构建。

## 1. 配置文件

所有普通配置在统一的 `<SOFTWARE_ROOT>/deploy/.env`。Ubuntu 默认 `/software/deploy/.env`，fnOS 默认 `/vol3/1000/software/deploy/.env`。敏感配置文件分别是 `/software/deploy/.secrets` 或 `/vol3/1000/software/deploy/.secrets`，但 **Agent 不需要新增密码、API Key 或 Token 配置项**；配对凭据由上游在本机生成和保存。

运行 `sudo bash deploy.sh env` 后用 `sudoedit /software/deploy/.env`（fnOS 修改相应路径），设置：

```dotenv
# 与 DOCKER_IMAGE_SOURCE 相同的 original/mirror 模式，但独立控制 Release 文件。
GITHUB_RELEASE_SOURCE=mirror
GITHUB_RELEASE_MIRRORS=ghproxy,ghfast,ghproxy-net
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
```

若服务器无法连接 GitHub，可把对应架构的两个文件上传到同一目录，例如 `/software/easyhostagent/easyhostagent-linux-amd64` 和 `/software/easyhostagent/easyhostagent-linux-amd64.sha256`，随后设置 `EASYHOSTAGENT_LOCAL_BINARY=/software/easyhostagent/easyhostagent-linux-amd64`。安装脚本在安装前校验 SHA-256；上传的文件保留原样，不需要手工更改可执行权限。留空仍按 `EASYHOSTAGENT_RELEASE` 下载，`GITHUB_RELEASE_SOURCE=mirror` 时自动轮换站点。两种模式统一使用 `sudo bash deploy.sh easyhostagent install` 和 `update`。**本地文件及同名校验文件必须来自可信 GitHub Release。**

**GitHub Release 文件加速**：在统一 `.env` 中设置 `GITHUB_RELEASE_SOURCE=mirror`，`GITHUB_RELEASE_MIRRORS` 默认顺序为 `ghproxy,ghfast,ghproxy-net`，分别对应 `gh-proxy.org`、`ghfast.top`、`ghproxy.net`。每次在线安装/更新从上一次首选站的下一个站开始；下载失败或 SHA-256 不一致则尝试下一站，最后尝试 GitHub 原站。轮换状态保存在 `<SOFTWARE_ROOT>/deploy/state/github-release-mirror.last`，不影响 Docker 的 `DOCKER_IMAGE_SOURCE`。`original` 仅直连官方，指定 `EASYHOSTAGENT_LOCAL_BINARY` 时不下载文件也不推进轮换。第三方代理不能等同于官方可信发布源；滚动开发版资产还可能存在缓存滞后，重要环境建议使用不可变版本并核对官方校验值。

安装后将配置同步到 `/etc/easyhostagent/agent.env`，保留其中其他非托管配置项。安装、更新不会重置 Agent 身份、配对授权或已有应用状态。开发版 `v0.1.0-appstore.dev` 是**发布资产可更新的滚动标签**；生产机器建议改为明确、不可变的正式版本号。相应的 AMD64 / ARM64 二进制、同名 `.sha256` 均由 GitHub Actions 生成。

## 2. 运行条件和网络

- 系统：Linux / fnOS，systemd 作为 init；CPU：AMD64 或 ARM64。
- 安装依赖：root、Bash、curl、sha256sum、install、mktemp、flock、systemctl；运行 Docker 应用管理功能还需本机可用的 Docker Engine。
- 监听：默认 `0.0.0.0:7018`，开放范围由防火墙限制。只有在信任隔离网络并配置访问来源限制时才改 `EASYHOSTAGENT_TRANSPORT=http`；HTTP 明文会暴露一次性配对码、Bearer Token 和操作参数，严禁未经保护直接对公网开放。HTTPS 使用 Agent 的自签名证书及 EasyNetTopo 的固定公钥指纹校验。
- 进程以 root 运行以管理本机 Docker；数据默认在 `/var/lib/easyhostagent`。标准 Deploy 应用安装到 `<SOFTWARE_ROOT>/<应用ID>/deploy/`，升级前已安装的隔离应用仍保留其原目录。
- Agent 无主动心跳、无定时上报；状态按需查询。未提供强制 CPU/RAM 最小值。

## 3. 配对认证（无需逐应用授权）

无需输入管理员密码。Agent 首次启动在数据目录生成自身 UUID 和 TLS 身份；在 Agent 所在机器可信终端查看：

```bash
sudo /usr/local/bin/easyhostagent -identity
sudo /usr/local/bin/easyhostagent -pairing-code
```

**推荐从 deploy 统一入口生成配对信息：**

```bash
cd /vol3/1000/software/deploy   # fnOS；Ubuntu 通常为 /software/deploy
sudo bash deploy.sh easyhostagent pairing
```

该命令不安装、不更新、不下载、不重启 Agent；检查本机 `easyhostagent.service` 正在运行，再从 `/etc/easyhostagent/agent.env` 安全读取实际数据目录，调用原生 `-pairing-code`，打印 Agent ID、TLS 公钥指纹、一次性配对码与 UTC 到期时间。**每次运行都会签发新的 10 分钟一次性码，使上一枚尚未使用的配对码失效**；现有 Agent 身份和已配对控制端授权不会因此被清除。只在可信本机终端运行，不要把输出粘贴到日志、CI 或公开聊天中。

配对码是**本机按需自动生成**的临时凭据。配对成功后，控制端 Token 由 Agent 签发并分别安全保存；它们不写入统一 `.secrets`，也不应放进公开日志或聊天。

**无需执行 `deploy.sh easyhostagent grant`，也无需配置 `EASYHOSTAGENT_APP_GRANTS`。** 已配对且通过令牌校验的 EasyNetTopo 可以管理可信 Git 应用源中的应用。升级前配置文件中已有的 `EASYHOSTAGENT_APP_GRANTS` 会保留但被新版 Agent 忽略；更新不会重置原配对身份。应用操作依然执行固定 Git 包校验、Compose 身份检查、路径隔离和卸载二次确认。

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
# 忽略已配置的 EASYHOSTAGENT_LOCAL_BINARY，强制重新下载并校验当前 Release：
sudo bash deploy.sh easyhostagent force-update
```

普通更新按 `EASYHOSTAGENT_LOCAL_BINARY` 选择使用本地包或 GitHub Release；`force-update` 无视本地包设置，强制重新下载当前 `EASYHOSTAGENT_RELEASE` 指向的发布资产并校验 SHA-256，并验证 SHA-256 后替换二进制，再同步 Agent 配置项并重启 systemd；现有身份、配对凭据、应用目录和 Docker 容器保留。更新过程中如发生下载或校验错误，公共下载模块会切换来源；全部失败则在替换二进制前退出。已存在由其他安装器管理的同名服务时会拒绝接管。如果此前已安装 EasyHostAgent Docker 容器，须先安全停止并移除该旧容器；新安装器会检测同名容器并拒绝同时运行，避免两个 Agent 共用端口与身份数据。

## 7. Deploy 应用目录与自动关联

标准 Docker 应用通过 deploy 仓库各自目录的 `app.yaml` 声明元数据、安装、更新、卸载和配置项。EasyNetTopo 同步可信来源后自动发现新应用；新安装应用使用 `<SOFTWARE_ROOT>/<应用ID>/deploy/`，调用来源中已适配的脚本，统一配置仍保存在 `<SOFTWARE_ROOT>/deploy/.env` 和 `.secrets`，默认卸载保留数据。

之前通过 `sudo bash deploy.sh <应用ID> install` 安装的 Compose 项目，只要 Docker 项目名、工作目录及配置文件路径严格匹配 `<SOFTWARE_ROOT>/<应用ID>/deploy/docker-compose.yaml`，且原始部署脚本存在且安全，EasyNetTopo 会使用已校验的固定 Git 应用包**自动建立管理关联**，无需逐个授权或手动点击接管。原有数据、密码和容器不因建立关联而改变。应用目录不匹配、来源冲突以及旧 OpenCode 项目名为 `deploy` 的情况，仅显示只读状态，不自动接管。

如果旧部署脚本缺失或不安全，可明确确认强制更新，由 Agent 从固定 Git 包按清单修复允许的普通部署文件，再执行更新；不会写入 `.env`、`.secrets` 或 `data`。新应用和旧应用都应通过可信来源版本、应用 ID 和 Compose 身份验证。

EasyHostAgent 自身是 systemd 原生服务，首次安装与卸载仍只能在目标主机终端完成。**EasyNetTopo 原生 Agent 卡片不提供卸载按钮；对已配对且在线的 Agent 提供可直接下发的「更新」「强制更新」操作。**

## 8. EasyNetTopo 远程自更新与恢复判定

控制端通过已配对的 Bearer Token 发送固定的 `POST /v1/host/maintenance/update` 或 `POST /v1/host/maintenance/force-update`。Agent 在 HTTP 返回 `202 queued` 后，使用独立的 systemd 延迟任务执行原生安装器，避免由自身进程直接重启自身造成任务丢失。请求不接受脚本路径、Shell 内容、额外参数或远程卸载。仅当 Agent 以 root 运行、系统安装标识存在、Deploy 脚本与配置文件安全可读、`systemd-run` 可用时允许排队；任务本身使用原有固定版本下载和 SHA-256 校验机制。

- **更新**：继续使用 `<SOFTWARE_ROOT>/easyhostagent/deploy/update.sh`，优先按统一 `.env` 中配置的本地安装包更新；否则下载 `EASYHOSTAGENT_RELEASE`。
- **强制更新**：使用 `<SOFTWARE_ROOT>/easyhostagent/deploy/install.sh force-update`，忽略本地安装包并重新下载当前配置的 Release，验证校验和后替换二进制。
- **连通性**：Agent 重启时短暂断联正常。控制端对比更新前后的 `agent_started_at`，只有配对身份仍有效且确认已重启，才报告「已重新连通」；这不等价于验证发布版本已更新。超过 10 分钟未确认重启并重新连接，只展示异常排查信息，不反复弹出离线失败提示。
- **排查**：在目标主机执行 `sudo systemctl status easyhostagent --no-pager`、`sudo journalctl -u easyhostagent-self-update.service -n 100 --no-pager`，并检查下载来源、版本配置以及监听地址。Agent 更新脚本的运行输出不回传控制端，避免意外泄露配置和凭据。

首次使用远程自更新前，需要在目标主机手动安装一次包含该 API 的新版 Agent；旧版 Agent 不会自动获得新接口。
