# EasyTier

这个目录使用统一的 **Web-managed Core** 模式部署 EasyTier。

Docker 部署现在只使用 **一个容器**。同一份 Compose 通过 `EASYTIER_ROLE` 区分两种角色：

- `cloud`：**管理面模式**，只运行 `easytier-web-embed`，提供 Web Console + Config Server；**不启动 `easytier-core`**。
- `intranet`：数据面节点，只运行 `easytier-core`，连接云端 Web Config Server。

这样 cloud 主机本身不会加入 EasyTier 虚拟网络，也不会成为 EasyTier Relay、Exit Node 或子网代理。需要组网的 fnOS / OpenWrt / Linux 节点继续作为独立 Core 节点运行。

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
| EasyTier Core TCP/UDP | 7005 | intranet / OpenWrt 等 Core 节点使用；cloud 不监听 |
| EasyTier RPC | 7006 | Core 节点默认仅 `127.0.0.1`；cloud 不监听 |
| Web Console | 7007 | cloud 模式 |
| Web Config Server | 7008/UDP | cloud 模式；异地节点接入时需可达 |

EasyTier 的数字型 `--listeners 7005` 会自动为部分协议使用 `7006`。为了避免与 RPC 7006 冲突，部署脚本明确使用：

```text
tcp://0.0.0.0:7005
udp://0.0.0.0:7005
```

而不是直接使用数字型 `7005`。

## 云端模式

云服务器配置：

```dotenv
EASYTIER_ROLE=cloud
EASYTIER_WEB_PORT=7007
EASYTIER_CONFIG_PORT=7008
EASYTIER_PRIVILEGED=false
EASYTIER_WEB_API_HOST=http://<浏览器可访问地址>:7007
EASYTIER_CONFIG_SERVER=
```

容器执行：

```text
sh /opt/easytier/cloud.sh
```

宿主机脚本位置：

```text
easytier/deploy/bash/cloud.sh
```

`cloud.sh` 现在只启动：

```text
easytier-web-embed
```

它提供两个控制面入口：

```text
Web Console   :7007/TCP
Config Server :7008/UDP
```

**cloud 模式不再启动 `easytier-core`。**

因此：

- 云服务器不会再获得 EasyTier 虚拟 IP（例如旧配置中的 `10.10.10.1` 将不再存在于云服务器上）。
- 云服务器不再监听 EasyTier Core 的 `7005/TCP+UDP`。
- 云服务器不再提供 Core RPC `7006`。
- 云服务器不承担 EasyTier Relay 数据中继。
- 云服务器不能作为 EasyTier Exit Node。
- 云服务器不会通过 EasyTier 导出本机子网。
- Web Console 与 Config Server 仍然正常工作，远端 Core 继续从这里接收配置。

这属于**管理面 / 数据面分离**：云端负责配置管理，实际组网流量由各 Core 节点之间直接建立连接。若节点之间无法直接连通，需要另行提供符合自身网络与服务商要求的数据中继方案，不再由这个 cloud 角色承担。

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

现有 `data/core` 和 `data/web` 不会删除。

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

cloud 模式日志中只有 Web Console / Config Server；不会再出现 cloud Core 日志。

## 网络与安全

cloud 模式只运行管理面：

```text
7007/TCP  Web Console
7008/UDP  Config Server
```

不再运行：

```text
7005/TCP+UDP  EasyTier Core Listener
7006          Core RPC
```

因此云端安全组建议：

- `7007/TCP` 只允许可信管理来源访问。
- `7008/UDP` 只允许需要接入 Config Server 的 EasyTier Core 节点访问，能限制来源时尽量限制。
- cloud 角色不需要因为 EasyTier 再开放 `7005/TCP`、`7005/UDP` 或 `7006`。
- 不要把 Web Console / Config Server 当作通用代理、VPN 出口或流量转发服务使用。

内网 Docker / OpenWrt Core 节点仍可使用：

```text
udp://<云服务器地址>:7008/admin
```

连接云端 Config Server。组网数据是否能 P2P 直连，取决于各 Core 节点的网络环境与 EasyTier 配置；cloud 管理节点不会再作为失败后的数据 Relay 兜底。
