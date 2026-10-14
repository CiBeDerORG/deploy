# Mihomo

使用 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 官方内核，提供 [MetaCubeXD](https://github.com/MetaCubeX/metacubexd) Web 管理页面。普通 Docker bridge 模式，**不开 TUN、不接管宿主机网络**。

## fnOS NAS 安装

在 deploy 仓库根目录执行：

```bash
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh env
sudo nano /vol3/1000/software/deploy/.env
sudo nano /vol3/1000/software/deploy/.secrets
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo
```

统一普通配置位于 `/vol3/1000/software/deploy/.env`。**安全默认值**：

```dotenv
SOFTWARE_ROOT=/vol3/1000/software
MIHOMO_MIXED_PORT=7011
MIHOMO_API_PORT=7012
MIHOMO_PROXY_BIND_IP=127.0.0.1
MIHOMO_API_BIND_IP=127.0.0.1
```

- `7011` 混合 HTTP/SOCKS5 代理：默认只在 NAS 宿主机回环地址发布。
- `7012` 同时承载 Web UI **和拥有管理权限的控制 API**：默认只在宿主机回环地址发布。浏览器页面可以加载不代表已获 API 操作权限；操作需设置 `MIHOMO_API_SECRET`。
- **不要为了省事设置 `MIHOMO_API_BIND_IP=0.0.0.0`。** 这会在 NAS 全部 IPv4 网卡发布管理端口，是否能从互联网访问还取决于网络路由、NAT 和防火墙，但可达的非授权设备会接触到该端口。
- NAS 专用局域网 IP 仅限制监听的目标接口，**不限制来源设备**；必须配合 fnOS/路由器防火墙限定可信管理 IP，绝不能将 `7012` 做公网端口映射。

### 在电脑上使用 Web 管理：两种方式

**方式 A：保持仅本机发布（最小暴露）**。从电脑建立 SSH 隧道（把示例中的地址替换为真实 NAS SSH 目标）：

```bash
ssh -L 7012:127.0.0.1:7012 <NAS_SSH_USER>@<NAS_LAN_IP>
```

然后电脑浏览器打开 `http://127.0.0.1:7012/ui/`，API 地址填 `http://127.0.0.1:7012`，无需开放 NAS 的 7012 入站端口。

**方式 B：直接通过 NAS 局域网 IP 访问**。先用 `ip -4 -br addr` 确认 NAS 实际局域网 IPv4，再将 `.env` 中的 `MIHOMO_API_BIND_IP` 改成那个真实地址（例如 `192.168.10.20`，仅为示例）。在 NAS 防火墙中仅允许指定管理设备的源 IP 访问 TCP 7012，禁止互联网/NAT 端口映射，之后执行：

```bash
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo update
```

浏览器打开 `http://<NAS_LAN_IP>:7012/ui/`，API 地址填 `http://<NAS_LAN_IP>:7012`（**不带** `/ui/`）。采用普通 HTTP 时仅建议用于可信局域网；跨不可信网络请使用 SSH/VPN 或可信 HTTPS 认证网关。

**已经使用前一版 `MIHOMO_API_BIND_IP=0.0.0.0` 的 NAS：** `deploy.sh env` 只增补缺失项，**不会自动覆盖真实 `.env`**。请主动检查并改为 `127.0.0.1` 或 NAS 专用 LAN IP，再执行上面的 update 命令。

### Web/API 密钥

敏感配置位于 `/vol3/1000/software/deploy/.secrets`：

```dotenv
# 首次安装留空时自动生成，远程开放 API 时要求至少 32 字符
MIHOMO_API_SECRET=
MIHOMO_PROXY_USER=deploy
# 首次安装留空自动生成
MIHOMO_PROXY_PASSWORD=
```

通过 NAS SSH 查看 API 密钥（避免向别人转发）：

```bash
sudo grep '^MIHOMO_API_SECRET=' /vol3/1000/software/deploy/.secrets
```

连接面板时输入 `MIHOMO_API_SECRET`，不要输入 HTTP/SOCKS5 代理账户密码。

## 代理与配置管理

首次安装将 `deploy/config.example.yaml` 复制为 `<SOFTWARE_ROOT>/mihomo/data/config.yaml`，再附加代理认证；**以后不会覆盖用户配置**。面板资源来自 MetaCubeXD 官方 `gh-pages` 压缩包，由 Mihomo 的 `external-ui-url` 下载并持久化到 `data/ui/`。若 NAS 无法连接 GitHub，检查 `docker logs mihomo`；必要时手动将官方已构建静态网页放进 `data/ui/`，包含 `index.html`。

初始规则 `MATCH,DIRECT` 仅供验证，不会自动提供额外代理线路。添加订阅、节点、代理组或规则请修改持久化的 `data/config.yaml`，然后执行 `sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo update` 做配置语法检测及重建。

代理认证初次写入 `data/config.yaml`；更换代理密码须同时更新该文件和 `.secrets`。本机代理示例 `http://deploy:<代理密码>@127.0.0.1:7011`，控制 API 的密钥与代理密码不同。API 密钥由官方 `CLASH_OVERRIDE_SECRET` 注入，不写进 `config.yaml`。

**其他 Docker 容器访问 Mihomo**：容器的 `127.0.0.1` 不是 NAS 宿主机的 `127.0.0.1`。推荐把需要代理的容器与 Mihomo 加入专用、无外部暴露的用户自定义 Docker 网络，使用服务名 `mihomo:7890`，并配置代理认证；两个独立 Compose 项目默认不共享网络。**不必为容器互访将宿主机代理端口改成 `0.0.0.0`。**
