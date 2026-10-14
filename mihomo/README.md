# Mihomo · MetaCubeXD 官方完整版

本模块从零编写部署脚本，使用官方 **MetaCubeXD All-in-One** 镜像
`ghcr.io/metacubex/metacubexd-server:latest`，它同时提供 Web、管理 Agent 和内置 Mihomo 内核。
不是旧版独立 Mihomo + 静态 `/ui/` 面板方案，也不再依赖 `external-ui-url` 下载网页资源。
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

Web 和内核 API 使用不同端口。安装时从 NAS 当前 IPv4 网卡自动生成 Mihomo 原生的 `external-controller-cors`，不增加额外的 Web Origin 环境变量。使用自定义域名等特殊来源时，直接在对应 Profile YAML 内修改官方字段。
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
