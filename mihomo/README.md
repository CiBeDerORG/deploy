# Mihomo

使用 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 官方内核和 [MetaCubeXD](https://github.com/MetaCubeX/metacubexd) Web 面板；普通 Docker bridge 模式，不启用 TUN、不接管宿主机网络。

## NAS 安装和访问

在 `deploy` 仓库根目录执行：

```bash
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh env
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo
```

统一普通配置位于 `/vol3/1000/software/deploy/.env`，**代理端口与 Web 端口分开配置**：

```dotenv
SOFTWARE_ROOT=/vol3/1000/software
MIHOMO_MIXED_PORT=7011
MIHOMO_PROXY_BIND_IP=127.0.0.1
MIHOMO_API_PORT=7012
MIHOMO_API_BIND_IP=0.0.0.0
```

- **代理端口 7011**：只发布至 NAS 宿主机的 `127.0.0.1`，不会因为开启 Web 而自动对其他设备开放代理。
- **Web/API 端口 7012**：发布到 NAS 全部 IPv4 网卡。在其他电脑或手机浏览器打开 `http://<NAS_IP>:7012/ui/`。如面板要求连接内核，API 地址是 `http://<NAS_IP>:7012`（不含 `/ui/`）。
- Web 与控制 API 同端口。API 操作需要单独的 `MIHOMO_API_SECRET`，并非代理用户名/密码；安装脚本在 Web 远程可访问时要求密钥至少 32 字符，留空首次安装会随机生成。
- `0.0.0.0` 是监听全部宿主机 IPv4 网卡，**不等于必然能从公网访问**，实际可达范围仍取决于 NAS 所在网络和防火墙。如果通过公网使用，建议额外使用 HTTPS 或可信专用网络。

**已有安装**：`deploy.sh env` 不会覆盖现有 `.env`，若其中仍为 `MIHOMO_API_BIND_IP=127.0.0.1`，请手动改成 `0.0.0.0`，然后在仓库根目录执行：

```bash
git pull origin main
sudo nano /vol3/1000/software/deploy/.env
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo update
```

## 管理密钥

统一敏感配置位于 `/vol3/1000/software/deploy/.secrets`：

```dotenv
# 留空首次安装自动生成并持久化
MIHOMO_API_SECRET=
MIHOMO_PROXY_USER=deploy
MIHOMO_PROXY_PASSWORD=
```

通过 NAS SSH 查看 Web 管理所需的 API 密钥：

```bash
sudo grep '^MIHOMO_API_SECRET=' /vol3/1000/software/deploy/.secrets
```

代理账号和密码与 Web API 密钥是两套凭据。

## 节点、订阅及持久化

首次安装从 `deploy/config.example.yaml` 生成 `<SOFTWARE_ROOT>/mihomo/data/config.yaml` 并附加代理认证，更新不会覆盖用户配置。MetaCubeXD 面板资源由内核根据 `external-ui-url` 下载到持久化的 `data/ui/`。NAS 无法下载时，先检查 `docker logs mihomo`，必要时将官方构建好的静态资源放入 `data/ui/`（含 `index.html`）。

初始规则 `MATCH,DIRECT` 只用于部署验证，不会自动提供额外代理线路。添加节点、订阅、代理组和规则请修改 `data/config.yaml`，再执行：

```bash
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo update
```

API 密钥通过官方 `CLASH_OVERRIDE_SECRET` 注入；初始代理密码写入 `data/config.yaml`，轮换代理密码时应同步修改 `.secrets` 和 `config.yaml`。

其他 Docker 容器的 `127.0.0.1` 不等于 NAS 宿主机回环地址。如 Sub2API 需要经 Mihomo 出站，应单独配置共享 Docker 网络，使其通过 `mihomo:7890` 并携带代理认证连接；**无需为容器互访把宿主机代理端口 7011 改成 0.0.0.0**。
