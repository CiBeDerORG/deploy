# EasyTier

本目录的 Docker 部署使用**一个容器**，通过 `EASYTIER_ROLE` 切换：

- `cloud`：同一容器运行 `easytier-web-embed`、Web Config Server 和**由本机 Web 管理的云端 Core**。
- `intranet`：仅运行 `easytier-core`，通过远端 Web Config Server 接收配置。

OpenWrt 不需要 Docker，使用 `easytier/openwrt/install.sh` 原生安装。

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

Compose 使用 host 网络、TUN 和稳定的宿主机 `/etc/machine-id`。

## 端口规划

| 用途 | 默认端口 | 说明 |
| --- | --- | --- |
| EasyTier Core Peer | 7005/TCP+UDP | **需要在云端 Web 的网络实例中添加 Listener** |
| Core RPC | 7006 | 仅本机 |
| Web Console | 7007/TCP | 限制为可信管理来源 |
| Web Config Server | 7008/UDP | 供云端自身、fnOS、OpenWrt 等节点接入 |

Listener 建议分别填写 `tcp://0.0.0.0:7005`、`udp://0.0.0.0:7005`，而非数字型 `7005`，避免部分协议自动占用相邻的 `7006` RPC 端口。

## 云端 cloud 模式

在 `<SOFTWARE_ROOT>/deploy/.env` 填写：

```dotenv
EASYTIER_ROLE=cloud
EASYTIER_PRIVILEGED=false
EASYTIER_PORT=7005
EASYTIER_RPC_PORT=7006
EASYTIER_WEB_PORT=7007
EASYTIER_CONFIG_PORT=7008
EASYTIER_WEB_API_HOST=http://<公网服务器IP>:7007
EASYTIER_CONFIG_SERVER=
```

云端 Core 沿用现有的 `/admin` Config Server 路径，不需要额外的 `EASYTIER_CLOUD_CONFIG_USER` 变量。其启动参数：

```text
--config-server udp://127.0.0.1:7008/admin
--config-dir /cloud-managed-core
--machine-id <宿主机 machine-id>
--rpc-portal 7006
```

云端网络名称、网络密钥、虚拟 IPv4 **完全由 Web 控制台配置**，不再需要提前填写 `EASYTIER_CLOUD_NETWORK_NAME`、`EASYTIER_CLOUD_IPV4` 和 `EASYTIER_CLOUD_NETWORK_SECRET`。旧文件中若仍存在这些变量，新版本不再读取。

### Web 首次配置云端 Core

1. 浏览器打开 `http://<公网IP>:7007`，使用现有 Web 管理账号登录，并查看云端 Core 是否已出现在设备列表。
2. 在机器列表找到这台云服务器，为其添加/编辑一个网络实例。网络名、密钥必须与 fnOS、OpenWrt 等现有节点一致。
3. 云端实例设置虚拟 IP（例如 `10.10.10.1/24`），添加 `tcp://0.0.0.0:7005`、`udp://0.0.0.0:7005` Listener，并保存启动。
4. 如果云端只做 P2P 协调，在**云端 Core 的网络实例**里配置 `disable_relay_data=true`（禁用业务数据 Relay）、`relay_all_peer_rpc=true`（保留 Peer RPC 协调）、`enable_exit_node=false`，建议 `private_mode=true`、`disable_upnp=true`、禁用出口节点和子网代理。
5. fnOS、OpenWrt 等节点仍连接 `udp://<公网IP>:7008/admin`，并将云端 `tcp://<公网IP>:7005` / `udp://<公网IP>:7005` 设为 Peer，以便协商 P2P。

**安全变化：** 原来的 `cloud-core/cloud.toml` 会在每次启动强制设置 no-relay；现在云端 Core 接受 Web 下发配置，这种**强制静态限制已经取消**。Web 可把 `disable_relay_data` 改回 `false`，导致云服务器中继数据。因此上面的安全标志必须在 Web 中设置并持续检查。当前部署不能同时承诺“Web 任意修改网络配置”与“脚本仍保证禁止中继”；后者需要 EasyTier Core 级策略支持。

### 从旧版静态 cloud Core 升级

旧版云端配置保存在 `<SOFTWARE_ROOT>/easytier/data/cloud-core/cloud.toml`。新版另用：

```text
<SOFTWARE_ROOT>/easytier/data/cloud-managed-core/
```

升级前备份 `<SOFTWARE_ROOT>/easytier/data/` 和 `<SOFTWARE_ROOT>/deploy/.env` / `.secrets`。原来的静态 `cloud.toml`、历史 `data/core/*.toml` **不会被删除，但不会自动加载或导入 Web**。升级后需要在 Web 中为云端机器重建或配置旧的网络名、密钥、IPv4（如 `10.10.10.1/24`）及 Listener/安全选项。在此之前云端 `7005` 不会自动监听，依赖云端 Peer 的节点可能暂时掉线。

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

cloud 模式的 Web 数据库：

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

现有 `data/core`、`data/cloud-core` 和 `data/web` 不会删除；Web 接管云端 Core 后将新增 `data/cloud-managed-core/`。升级后需到 Web 重新配置云端网络。

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

cloud 模式的 Web Console、Config Server 与 cloud Core 都在同一个 `easytier` 容器日志中。启动时会提示 Web 接入地址及需要在 Web 禁用数据中继，不再声称 Relay 被脚本锁定。

## 网络与安全

cloud 模式需要放行：

```text
7005/TCP+UDP  cloud Core 的 Peer 监听（需在 Web 下发）
7007/TCP      Web Console（建议限制可信管理来源）
7008/UDP      Config Server
```

`7006` RPC 只在本机监听，无需放开公网。`7008/UDP` 可在不影响异地接入的前提下尽量限制来源。

**重要：** cloud Core 使用自身 Config Server，所以 Relay、Exit Node、UPnP 等都由 Web 下发的云端实例 flags 决定。要求纯 P2P 协调时，请在 Web 中将 `disable_relay_data` 设置为 `true`，`relay_all_peer_rpc` 设置为 `true`，并关闭 Exit Node 和 UPnP；任何再次编辑云端配置后都应复核。Web 若允许中继，则可能使用云端流量作为数据中转。

内网 Docker / OpenWrt 仍使用 `udp://<公网IP>:7008/admin` 接入 Web Config Server。
