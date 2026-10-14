# Mihomo · MetaCubeXD All-in-One（官方完整版）

本模块取代旧版独立内核 + 静态面板，使用官方镜像
[ghcr.io/metacubex/metacubexd-server](https://github.com/MetaCubeX/metacubexd)。
完整服务包含 Web、控制 Agent、内置 Mihomo 内核，支持网页导入订阅 URL、
编辑 YAML/Profiles、订阅刷新与内核管理。镜像自带 Web 资源，不再设置
`external-ui-url` 下载静态页面。

官方参考：[README / All-in-One](https://github.com/MetaCubeX/metacubexd#3-all-in-one-server-docker)
与 [官方 Compose](https://github.com/MetaCubeX/metacubexd/blob/main/docs/docker-compose.yml)。

## 安装及访问

从 deploy 根目录运行 `sudo bash deploy.sh env`，再执行 `sudo bash deploy.sh mihomo`。

| .env 变量 | 默认 | 含义 |
| --- | --- | --- |
| MIHOMO_MIXED_PORT | 7011 | NAS 本机代理，容器内 7890 |
| MIHOMO_API_PORT | 7012 | Web/Agent，**不是旧版内核 API** |
| MIHOMO_CORE_API_PORT | 7013 | 内核 API，容器内 9090 |
| MIHOMO_PROXY_BIND_IP | 127.0.0.1 | 代理默认不发布到 NAS 局域网 |
| MIHOMO_API_BIND_IP | 0.0.0.0 | Web 可以在 LAN/EasyTier 访问（需网络访问控制） |
| MIHOMO_CORE_API_BIND_IP | 0.0.0.0 | 浏览器直连内核 API；需网络访问控制 |
| MIHOMO_WEB_ORIGIN | 留空 | 自定义 Web 浏览器来源，如 http://10.10.10.2:7012，不带路径 |

打开 **http://10.10.10.2:7012/**，不再使用旧版的 `/ui/`。
若面板要求连接内核，填写 **http://10.10.10.2:7013**，Secret
为原来的 MIHOMO_API_SECRET。因为 7012 与 7013 是不同源，首次生成的
`deploy-web-cors` merge Profile 会将主机 IPv4 地址（包含被系统报告出来的
EasyTier 地址）和 MIHOMO_WEB_ORIGIN 作为准确 CORS 来源；不使用通配符。
如果访问域名或网络发生变化，须在 Web 中更新这个 overlay 并重新激活，
或在首次部署前设好 MIHOMO_WEB_ORIGIN。

.secrets 包含 MIHOMO_API_SECRET（沿用旧值，现注入官方 CLASH_SECRET），以及
新增的 MIHOMO_CONTROL_TOKEN（注入官方 CONTROL_TOKEN，留空自动生成）。
**CONTROL_TOKEN 会由官方服务提供给浏览器，不能当作网页登录认证。**
没有旧配置的全新安装才用 MIHOMO_PROXY_USER / MIHOMO_PROXY_PASSWORD
生成代理认证。自定义非空凭据按项目 AGENTS.md 原样保留，不添加 hex 或长度限制。

## 旧版迁移与持久化

若发现旧版的 `<SOFTWARE_ROOT>/mihomo/data/config.yaml` 且完整版数据尚未初始化，
安装器会保留旧文件，同时首次创建：

- `mihomo/data/backup/pre-all-in-one/config.yaml`：独立只读权限备份；
- `mihomo/data/all-in-one/profiles/deploy-initial.yaml`：旧配置的副本，保留认证、节点及规则；
- `mihomo/data/all-in-one/profiles/deploy-web-cors.yaml`：跨 Profile 使用的浏览器来源 overlay；
- `mihomo/data/all-in-one/active.yaml`：Agent 首次运行配置；
- `mihomo/data/all-in-one/profiles/index.json` 与 `state.json`：Agent Profile 元数据。

只在副本中删除旧 `external-ui` 和 `external-ui-url` 两个配置项，
不改动原来的 config.yaml，也不重新生成旧账号密码。新的 Agent 将管理并注入
`external-controller`、`secret`、`mixed-port`。现有完整版本的 Profiles 与
active.yaml 更新时不覆写。旧配置的认证以旧 config.yaml 为准而不是另取
.secrets 密码。网页版导入新订阅后记得激活对应 Profile。

需要 SSH 手工编辑时请编辑 `data/all-in-one/profiles/<id>.yaml` 的配置源，
不要编辑可能由 Agent 自动重新生成的 `active.yaml`。已有自定义 Profile 由
官方 Agent 管理，不会在每次部署脚本更新时重置。

切换使用相同容器名 `mihomo`，因此旧容器会有短暂重建中断；
拉取和预检新镜像安排在重建旧容器之前。**如镜像下载失败，旧容器不变。**
若新容器在切换后失败，原始 config.yaml、备份及完整数据仍在，但
安装器不会擅自执行未经测试的自动回滚。建议切换前备份整个 mihomo/data。

## 安全和网络

普通 Docker bridge 模式；不启用 TUN / host / NET_ADMIN / privileged，
也不挂载 Docker Socket，不接管 fnOS 或 EasyTier 网络。
官方的 CONTROL_TOKEN **不是 UI 登录口令**；7012 和 7013 均须通过 NAS 防火墙、
受信任私网或带身份验证的反向代理限制来源，严禁无保护映射公网。

保留内部 Docker `proxy-net` 和同名容器，业务容器原有
`mihomo:7890` 代理地址不变；首次使用可执行
`sudo bash deploy.sh proxy connect sub2api`，目标容器重建后需要重新连接。
接入 Docker 网络不会自动改变该应用的 HTTP_PROXY/HTTPS_PROXY。

更新：`sudo bash deploy.sh mihomo update`。检查：
`docker logs --tail=100 mihomo`；
Web 健康接口是 `http://127.0.0.1:7012/api/control/health`，
7013 的 `/version` 需要携带 MIHOMO_API_SECRET。
