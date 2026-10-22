# Mihomo · MetaCubeXD 官方完整版

原有 Docker 安装保持官方 **MetaCubeXD All-in-One** 镜像
`ghcr.io/metacubex/metacubexd-server:latest`，新增**宿主机原生 systemd 安装**：
从官方发布版源码构建同一套 Web + 管理 Agent，并安装发布版对应的 Mihomo 内核；
不是只有静态面板的方案。两种模式共用 Profile 与凭据，但不能同时运行。
官方文档：[MetaCubeXD](https://github.com/MetaCubeX/metacubexd) ·
[官方 Compose 示例](https://github.com/MetaCubeX/metacubexd/blob/main/docs/docker-compose.yml)。

## 固定沿用既有端口

| .env 配置 | 默认值 | 容器内部 | 用途 |
| --- | --- | --- | --- |
| MIHOMO_MIXED_PORT | **7011** | 7890 | HTTP/SOCKS5 代理；默认仅 NAS 本机 127.0.0.1 |
| MIHOMO_API_PORT | **7012** | 8080 | 完整 Web + Agent（为兼容旧 .env 保留原变量名） |
| MIHOMO_CORE_API_PORT | **7013** | 9090 | 新增的内核 Clash API |
| MIHOMO_PROXY_BIND_IP | 127.0.0.1 | — | 7011 不向其他设备发布 |
| MIHOMO_API_BIND_IP | 0.0.0.0 | — | 7012 支持可信 LAN / EasyTier |
| MIHOMO_CORE_API_BIND_IP | 0.0.0.0 | — | 7013 供浏览器直连，需限制来源 |

Web 和内核 API 使用不同端口。**首次初始化时**，安装器从 NAS 当前 IPv4 网卡生成 Mihomo 原生 `external-controller-cors`，并读取统一 `.env` 中**已有的 `MYAI_IP`**，追加 `http://<MYAI_IP>:7012` 作为公网 IP 的 Web 来源（没有填写则不追加；如与本机 IP 重复则只保留一份）。不新增 Mihomo 环境变量。如果采用 HTTPS 域名反向代理，应在原生 Profile YAML 中配置该 HTTPS 域名来源；`MYAI_IP` 只生成当前 HTTP 7012 入口。已有完整版 Profiles 更新时不会被安装器覆写，修改来源后需在 Web 管理界面重新激活配置。
新版管理页是 **http://10.10.10.2:7012/**，不是旧的 `/ui/`。
面板需要连接内核时填 **http://10.10.10.2:7013** 和原来的 `MIHOMO_API_SECRET`。
默认跨端口 CORS 使用当前 NAS IPv4 对应的浏览器来源，不设置 `*`。

## 配置与安装

在 deploy 根目录运行：

```bash
sudo bash deploy.sh env
sudo bash deploy.sh mihomo
# 后续更新
sudo bash deploy.sh mihomo update
```

`.secrets` 中的 `MIHOMO_API_SECRET` 继续作为官方 `CLASH_SECRET`，
新增 `MIHOMO_CONTROL_TOKEN` 对应官方 Agent 的 `CONTROL_TOKEN`；
两项留空才自动生成，已填写的值原样保留，不自行限定长度或字符集。
`MIHOMO_PROXY_USER` / `MIHOMO_PROXY_PASSWORD` 仅用于**没有旧 config.yaml 的全新初始化**；
迁移旧数据时完全沿用旧配置内的 authentication，不修改、重置或再生成旧代理密码。

**安全提醒：官方 All-in-One 会向同源浏览器提供 CONTROL_TOKEN，因此它不是网页登录密码。**
务必只允许可信来源访问 7012/7013，可通过 NAS 防火墙、EasyTier 可信网络、
或另设带真正登录认证的 HTTPS 反向代理保护。禁止无保护暴露至公网。
不需要 Docker Socket、host 网络、TUN、NET_ADMIN 或 privileged；
不接管 fnOS / EasyTier 网络。

## 旧配置和完整版本的数据

每次执行 `deploy.sh mihomo`（包括仅同步）都会从 NAS 镜像目录精确清理已废弃的旧脚本、旧模板、旧测试，不清理运行时的 `data/`、真实 `.env` 或 `.secrets`。

重写/删除的是仓库**部署源码**，不删除 NAS 上的运行数据：
- 旧 `mihomo/data/config.yaml` 保留，并只在首次迁移复制备份到
  `mihomo/data/backup/pre-all-in-one/config.yaml`。
- 旧配置只在新 Profile 副本中删除已过时的 `external-ui` 与 `external-ui-url`，
  其他节点、规则、认证不主动改写。
- 新版实际持久化目录：`mihomo/data/all-in-one/`；官方 Agent 管理
  `profiles/index.json`、`profiles/state.json`、各个 `profiles/*.yaml` 和
  `active.yaml`。
- 首次初始化生成原生 Web CORS 与原代理认证 overlay，防止在网页导入/启用
  新订阅 Profile 后丢失代理认证。已有的完整版 Profile/active.yaml 在更新时不覆盖。
- 网页添加订阅、编辑 YAML、切换配置均走官方管理功能；SSH 修改时应编辑
  `profiles/<ID>.yaml`，不要直接改自动生成的 `active.yaml`。
- 首次切换前先拉取、检查镜像并验证新配置，再替换同名 mihomo 容器。
  切换仍会短暂停止代理；失败时旧文件和备份保留，但不会未经测试擅自回滚旧容器。
  建议自己再额外备份整个 `mihomo/data`。

## 宿主机原生安装：完整 Web + Agent + 内核（不使用 Docker）

适用于 Linux / fnOS / Ubuntu（需 **systemd + glibc、amd64 或 arm64**），不要求安装或启动 Docker。
**原 Docker 安装、Compose、proxy-net 和默认命令不变**。原生方式是显式选择的：

```bash
# 首次使用（先在 deploy 仓库目录）
sudo bash deploy.sh env
sudo bash deploy.sh mihomo host

# 今后更新官方 MetaCubeXD 发布版（仓库先 git pull）
sudo bash deploy.sh mihomo host-update

# 查看状态、日志
sudo systemctl status deploy-mihomo
sudo journalctl -u deploy-mihomo -f
```

宿主机安装会把官方 **Node.js 22、MetaCubeXD Web/Agent、对应版本的
Mihomo 二进制**放在 `<SOFTWARE_ROOT>/mihomo/runtime/host/`，使用
`deploy-mihomo.service` 启动，系统重启后自动运行。Node.js 下载会根据官方
SHA256 清单验证；源码通过上游官方发布 tag 获取，并用其锁定的 pnpm 依赖构建。
因此首次安装/升级需要能访问 GitHub、nodejs.org 和 npm registry，并可能需要一定的磁盘空间/内存进行 UI 构建。
不执行 apt 安装，不改系统 Node 或 Docker 镜像。

| 内容 | Docker 模式 | 宿主机模式 |
| --- | --- | --- |
| 入口 | `deploy.sh mihomo` / `mihomo update` | `deploy.sh mihomo host` / `mihomo host-update` |
| Web / Agent | 官方镜像内部 `8080` → `7012` | 官方 Nitro/Agent 直接监听 `7012` |
| 内核 API | `9090` → `7013` | 直接监听 `7013` |
| 混合代理 | `7890` → `7011` | 直接监听 `7011` |
| 数据/订阅/切换状态 | `mihomo/data/all-in-one/` | **相同目录，不另建 Profile** |
| 统一参数 | `deploy/.env`、`deploy/.secrets` | **相同文件、相同端口与密钥** |
| 管理方式 | `docker compose` | `systemctl` / `journalctl` |

宿主机原生同样使用 Web 的根地址 `http://<NAS-IP>:7012/`；面板内配置
`http://<NAS-IP>:7013` 与 `MIHOMO_API_SECRET`。
代理默认只监听 `127.0.0.1:7011`。原生运行没有 Docker 的端口映射隔离，
因此在**内核启动时生成临时监听覆盖配置**，保障
`MIHOMO_PROXY_BIND_IP` 默认值有效；**不会改动** `active.yaml`、已有订阅、
Profiles、认证或 Docker 代理设置。
`MIHOMO_API_BIND_IP` 用于 Web；原生 `MIHOMO_CORE_API_BIND_IP` 支持
`0.0.0.0` 和 `127.0.0.1`（受上游 Agent 的本机内核探活机制限制）。
原生模式不会自动打开 TUN，也不会自动接管 NAS 的系统代理。

**切换注意：** 端口和 Profile 共用，同一时刻只能运行一种模式。
如 Docker `mihomo` 仍在运行，宿主机安装会明确报错，**不会自动停掉或删除 Docker 容器**。
需自行执行 `docker stop mihomo`，然后运行 `deploy.sh mihomo host`。
需要切回 Docker 时：

```bash
sudo systemctl stop deploy-mihomo
sudo bash deploy.sh mihomo update
```

宿主机模式不运行名为 `mihomo` 的 Docker 容器，所以既有 Docker 业务容器
**不能继续用 `mihomo:7890`** 访问它；若要让这些业务使用宿主机代理，
需自行配置可达的宿主机地址和 `7011`，并按需放开绑定地址及网络访问权限。
切回 Docker 后原 `proxy-net` 与 `mihomo:7890` 方式仍可继续使用。
两种方式均不应把 Web/Agent 和内核 API 直接暴露到不可信公网；
官方 `CONTROL_TOKEN` 不是真实的网页登录保护。

## Docker 内部代理网络

仍使用本机 internal bridge `proxy-net`，正式容器继续叫 `mihomo`；
其他已加入网络的业务容器保持 `mihomo:7890` 作为代理地址，无需修改端口。

```bash
sudo bash deploy.sh proxy status
sudo bash deploy.sh proxy connect sub2api
sudo bash deploy.sh proxy status sub2api
sudo bash deploy.sh proxy disconnect sub2api
```

接入网络只解决容器互通，不会自动修改业务应用的 `HTTP_PROXY/HTTPS_PROXY`；
重建**目标业务容器**后需要再次 connect。数据库和 Redis 不必接入。

## 启动验收

```bash
sudo docker logs --tail=100 mihomo
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7012/api/control/health
```

Web 健康返回 200 不代表代理内核一定正常；安装脚本还会独立验证容器内
`http://127.0.0.1:9090/version`。fnOS 上对 7011/7012/7013 和实际订阅下载
仍需要现场验收，GitHub CI 无法代替真实 NAS 网络环境。
