# EasyTier

这个目录使用统一的 **Web-managed + cloud P2P coordinator** 模式部署 EasyTier。

Docker 部署只使用 **一个容器**。同一份 Compose 通过 `EASYTIER_ROLE` 区分两种角色：

- `cloud`：同时运行 `easytier-web-embed` 和一个**受限的 cloud Core**。Web 负责管理其他节点；cloud Core 只负责节点接入、Peer RPC 与 P2P 打洞协调，禁止业务数据 Relay 和 Exit Node。
- `intranet`：数据面节点，只运行 `easytier-core`，连接云端 Web Config Server。

cloud Core 使用独立静态配置，不连接 Web Config Server，因此 Web 页面不能把它重新配置成 Relay / Exit Node。fnOS / OpenWrt / Linux 等节点仍继续由云端 Web 管理。

OpenWrt 不使用 Docker，继续由 `easytier/openwrt/install.sh` 安装原生 Core。

## Docker 目录

```text
easytier/deploy/
├── bash/
│   ├── cloud.sh
│   └── intranet.sh
├── docker-compose.yaml
├── install.sh
└── update.sh
```

`docker-compose.yaml` 不再直接塞一大串 EasyTier 启动参数，只负责提供容器、host 网络、TUN、权限、持久化目录以及选择启动脚本。

## 端口规划

| 用途 | 端口 | 监听范围 |
|---|---:|---|
| EasyTier Core TCP/UDP | 7005 | cloud P2P 协调 Core 与其他 Core 节点使用 |
| EasyTier RPC | 7006 | cloud / intranet Core 默认仅 `127.0.0.1` |
| Web Console | 7007 | cloud 模式 |
| Web Config Server | 7008/UDP | cloud 模式；异地节点接入时需可达 |

EasyTier 的数字型 `--listeners 7005` 会自动为部分协议使用 `7006`。为了避免与 RPC 7006 冲突，部署脚本明确使用：

```text
tcp://0.0.0.0:7005
udp://0.0.0.0:7005
```

而不是直接使用数字型 `7005`。

## 云端模式

云端同时提供：

```text
7005/TCP+UDP  cloud P2P 协调 Core
7006          Core RPC（仅本机）
7007/TCP      Web Console
7008/UDP      Web Config Server
```

推荐配置：

```dotenv
EASYTIER_ROLE=cloud
EASYTIER_PRIVILEGED=false
EASYTIER_WEB_API_HOST=http://<浏览器可访问地址>:7007
EASYTIER_CONFIG_SERVER=

# 可选：升级旧部署时通常无需填写，会从 data/core/*.toml 自动迁移
EASYTIER_CLOUD_NETWORK_NAME=
EASYTIER_CLOUD_IPV4=
```

网络密钥属于敏感配置，放在 `.secrets`：

```dotenv
EASYTIER_CLOUD_NETWORK_SECRET=
```

### cloud Core 的安全模式

`cloud.sh` 会为 cloud Core 生成独立配置：

```text
<SOFTWARE_ROOT>/easytier/data/cloud-core/cloud.toml
```

首次升级时，如果这个文件还不存在，会尝试从旧：

```text
<SOFTWARE_ROOT>/easytier/data/core/*.toml
```

自动读取原来的 `network_name`、`network_secret` 和 `ipv4`。因此已有部署通常可以继续保留原来的云端虚拟 IP，例如 `10.10.10.1`。

如果是全新部署，没有旧 Core 配置，则必须显式填写：

```dotenv
EASYTIER_CLOUD_NETWORK_NAME=<与组网节点一致的网络名>
EASYTIER_CLOUD_IPV4=10.10.10.1/24
```

以及：

```dotenv
EASYTIER_CLOUD_NETWORK_SECRET=<与组网节点一致的网络密钥>
```

生成的 cloud Core 固定启用：

```toml
[flags]
enable_exit_node = false
private_mode = true
relay_all_peer_rpc = true
relay_network_whitelist = ""
disable_relay_data = true
disable_upnp = true
enable_udp_broadcast_relay = false
```

含义：

- `relay_all_peer_rpc = true`：允许转发 Peer RPC，帮助其他节点发现彼此并协商 P2P。
- `disable_relay_data = true`：禁止 cloud Core 转发业务数据。
- 空 `relay_network_whitelist`：进一步阻止 TUN 数据经过该节点中继。
- `enable_exit_node = false`：禁止成为 Internet Exit Node。
- `private_mode = true`：限制不同网络密钥的外部网络接入。
- `disable_upnp = true`：云服务器不尝试通过 UPnP 自动开放额外端口。

cloud Core **故意不使用 `--config-server`**。这是为了避免 Web Console 后续下发配置，把 Relay / Exit Node 等能力重新打开。Web Console 仍正常管理 fnOS / OpenWrt / 其他 Core，只是 cloud Core 自身改为本地静态安全配置。

### P2P 工作方式

其他节点仍应把云端 `7005` 配置为可连接的 Peer / Public Server。流程是：

```text
FNOS/OpenWrt
     │
     ├── 连接 cloud Core :7005
     │       └── Peer RPC / 节点发现 / P2P 协商
     │
     └──────────── P2P 直连另一节点
```

P2P 成功后，业务数据直接在节点之间传输，不经过 cloud Core。

如果 P2P 打洞失败，因为 cloud Core 已禁止数据 Relay，不会自动退回：

```text
节点 A -> cloud Relay -> 节点 B
```

这种情况下两端会通信失败，而不是让云服务器承担业务流量中继。

## 内网 Docker 模式

fnOS、普通 Linux 或其他 Docker 内网节点可使用同一份 Compose，只把角色改成：

```dotenv
EASYTIER_ROLE=intranet
EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_PRIVILEGED=true
EASYTIER_CONFIG_SERVER=udp://<公网服务器IP>:7008/admin
```

`EASYTIER_WEB_API_HOST` 在 intranet 模式不使用。

容器执行：

```text
sh /opt/easytier/intranet.sh
```

宿主机脚本位置：

```text
easytier/deploy/bash/intranet.sh
```

实际只启动：

```text
easytier-core \
  --config-server udp://<公网服务器IP>:7008/admin \
  --config-dir /config \
  --machine-id <宿主机 /etc/machine-id> \
  --listeners tcp://0.0.0.0:7005,udp://0.0.0.0:7005 \
  --rpc-portal 7006
```

内网节点不再启动自己的 Web Console，所有配置统一由云端 Web 管理。

fnOS 如果出现：

```text
rust tun error Operation not permitted
```

将：

```dotenv
EASYTIER_PRIVILEGED=true
```

普通 Ubuntu/Linux 通常可以保持 `false`。

## 持久化

intranet Core 的 Web 下发配置：

```text
<SOFTWARE_ROOT>/easytier/data/core/
```

cloud 模式本身不运行 Core；cloud 的 Web 数据库：

```text
<SOFTWARE_ROOT>/easytier/data/web/et.db
```

宿主机 `/etc/machine-id` 只读挂载进容器，保证容器重建以后 Web Console 仍然识别为同一台机器。

## 安装 / 更新

在 deploy 仓库根目录：

```bash
sudo bash deploy.sh env
sudo bash deploy.sh easytier
```

更新：

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh easytier update
```

从旧双容器版本升级时，安装脚本会自动删除旧：

```text
easytier-web
easytier-node
```

最终只保留：

```text
easytier
```

现有 `data/core` 和 `data/web` 不会删除；首次启用 no-relay cloud Core 时会新增 `data/cloud-core/cloud.toml`。

## OpenWrt 安装

OpenWrt 不运行 Docker Web 容器，只安装 EasyTier Core，并接入云端 Web Config Server。

脚本：

```text
easytier/openwrt/install.sh
```

首次安装：

```bash
sh install.sh --config-server udp://<公网服务器IP>:7008/admin
```

再次执行同一命令即可升级。脚本会先下载并验证新版本，然后停止旧 Core、原子替换二进制、启动并检查；如果新版本启动失败，会尝试恢复旧二进制。

脚本默认：

```text
RPC Portal     127.0.0.1:7006
TUN 名称约定    tun0
Listener 约定   7005/TCP + 7005/UDP
Config Server   云端 :7008
```

**注意：Web Config Server 模式下，Listener 和 `dev_name` 属于 Web 下发的网络实例配置。安装脚本不会通过 Core 启动参数强行覆盖 Web 配置。**

因此 OpenWrt 对应节点在 Web Console 中应设置：

```text
dev_name = tun0

Listener:
tcp://0.0.0.0:7005
udp://0.0.0.0:7005
```

如果 Web 中使用其它 TUN 名或 Listener 端口，安装时同步指定：

```bash
sh install.sh \
  --config-server udp://<公网服务器IP>:7008/admin \
  --tun-name <实际TUN名称> \
  --port <实际Listener端口>
```

脚本会：

- 自动识别 EasyTier 官方 Linux release 架构。
- 安装 `curl` / `unzip`，缺少 TUN 时尝试安装 `kmod-tun`。
- 下载并验证 `easytier-core` / `easytier-cli`。
- 创建并持久化 `/etc/easytier/machine-id`。
- 将 Web 下发的 TOML 保存到 `/etc/easytier/config/`。
- 写入 `/etc/config/easytier`。
- 创建 `/etc/init.d/easytier` procd 服务并设置开机自启。
- 默认创建 EasyTier 防火墙 zone，允许 `EasyTier -> LAN` 和 `LAN -> EasyTier` 转发。
- 默认**不**向 WAN 开放 7005，避免无必要的公网暴露。
- 支持 `udp://`、`tcp://`、`ws://`、`wss://` Config Server 地址。
- 升级失败时尝试回滚旧二进制。

需要让公网主动连接这台 OpenWrt 的 7005/TCP+UDP 时：

```bash
sh install.sh \
  --config-server udp://<公网服务器IP>:7008/admin \
  --open-wan-listener
```

不希望脚本修改 OpenWrt 防火墙时：

```bash
sh install.sh \
  --config-server udp://<公网服务器IP>:7008/admin \
  --no-firewall
```

OpenWrt 常用命令：

```bash
/etc/init.d/easytier status
/etc/init.d/easytier restart
logread -e easytier
easytier-cli -p 127.0.0.1:7006 node
```

## 查看 Docker 状态

```bash
cd <SOFTWARE_ROOT>/easytier/deploy

docker compose \
  --env-file <SOFTWARE_ROOT>/deploy/.env \
  --env-file <SOFTWARE_ROOT>/deploy/.secrets \
  ps

docker compose \
  --env-file <SOFTWARE_ROOT>/deploy/.env \
  --env-file <SOFTWARE_ROOT>/deploy/.secrets \
  logs -f easytier
```

cloud 模式的 Web Console、Config Server 与 cloud Core 都在同一个 `easytier` 容器日志中。启动时会明确打印 `Relay: disabled`、`ExitNode: disabled` 和 `Peer RPC: enabled for P2P coordination`。

## 网络与安全

cloud 模式需要：

```text
7005/TCP+UDP  EasyTier P2P 协调 Core
7007/TCP      Web Console
7008/UDP      Config Server
```

`7006` RPC 只监听本机，无需开放公网。

安全建议：

- `7007/TCP` 只允许可信管理来源访问。
- `7008/UDP` 只允许需要接入 Config Server 的 Core 节点访问，能限制来源时尽量限制。
- `7005/TCP+UDP` 仅用于 EasyTier Peer 连接与 P2P 协调。
- cloud Core 固定禁止数据 Relay 与 Exit Node，不应启用 SOCKS5、VPN Portal、端口转发或子网代理。
- cloud Core 的 `data/cloud-core/cloud.toml` 是安全边界，不通过 Web Console 修改。

内网 Docker / OpenWrt Core 节点仍使用：

```text
udp://<云服务器地址>:7008/admin
```

连接云端 Config Server。实际业务流量优先走节点间 P2P；如果 P2P 无法建立，本部署不会使用 cloud Core 作为业务数据 Relay 兜底。
