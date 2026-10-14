# Mihomo

使用 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 官方内核，自带 [MetaCubeXD](https://github.com/MetaCubeX/metacubexd) Web 管理面板。默认普通 Docker bridge 模式，**不开 TUN、不接管宿主机网络**。

## fnOS NAS 安装

在仓库根目录执行：

```bash
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh env
sudo nano /vol3/1000/software/deploy/.env
sudo nano /vol3/1000/software/deploy/.secrets
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo
```

统一普通配置 `/vol3/1000/software/deploy/.env` 的相关设置：

```dotenv
SOFTWARE_ROOT=/vol3/1000/software
MIHOMO_MIXED_PORT=7011
MIHOMO_API_PORT=7012
MIHOMO_PROXY_BIND_IP=127.0.0.1
MIHOMO_API_BIND_IP=0.0.0.0
```

- 混合 HTTP/SOCKS5 代理 `7011` 默认仅允许宿主机本地使用。
- **Web UI 与控制 API 共用 `7012`**。新安装模板将其映射到宿主机所有 IPv4 地址，访问 `http://<NAS局域网IP>:7012/ui/`；安全起见，更推荐把 `MIHOMO_API_BIND_IP` 填为 NAS 的实际局域网 IPv4，以避免监听其他网卡。需要通过 EasyTier 访问时，绑定适当接口 IP 并设置防火墙规则。
- 严禁在路由器上映射 `7012` 到公网；NAS 防火墙应仅允许可信管理设备/IP 访问。该端口不仅是静态网页，还包含有权限修改代理配置的 API。当前 HTTP 部署仅建议可信网络使用，跨公网需通过 VPN/HTTPS 认证代理。
- **已有安装不会自动更改**真实 `.env` 中的旧监听值 `127.0.0.1`。修改后运行 `sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo update` 才能从电脑浏览器打开。

统一敏感配置 `/vol3/1000/software/deploy/.secrets`：

```dotenv
# 留空时首次安装自动生成并持久化；远程开放 API 时要求至少 32 个字符
MIHOMO_API_SECRET=
MIHOMO_PROXY_USER=deploy
# 留空时首次安装自动生成
MIHOMO_PROXY_PASSWORD=
```

首次生成的 Web/API 密钥可以通过 NAS SSH 查看（避免截屏、共享）：

```bash
sudo grep '^MIHOMO_API_SECRET=' /vol3/1000/software/deploy/.secrets
```

浏览器进入 `http://<NAS局域网IP>:7012/ui/`。如果面板提示添加内核连接，API 地址填 `http://<NAS局域网IP>:7012`（**不带** `/ui/`），Secret 填 `MIHOMO_API_SECRET` 的值；不要填代理账号密码。

## 配置与更新

首次安装从 `deploy/config.example.yaml` 生成 `<SOFTWARE_ROOT>/mihomo/data/config.yaml`，附加初始代理认证；**以后不会覆盖用户配置**。面板资源来自官方 MetaCubeXD `gh-pages` 压缩包，由 Mihomo 的 `external-ui-url` 下载并持久化到 `data/ui`。如果 NAS 无法连接 GitHub 导致面板打不开，先检查 `docker logs mihomo`，或手动将该官方分支预编译资源放进 `data/ui/`，确保其中含 `index.html`。

初始规则 `MATCH,DIRECT` 只用于部署验证，不提供额外代理线路。添加节点、订阅、代理组或规则，请编辑运行目录中的 `data/config.yaml`，再执行：

```bash
sudo env SOFTWARE_ROOT=/vol3/1000/software bash deploy.sh mihomo update
```

API 密钥通过官方 `CLASH_OVERRIDE_SECRET` 环境变量传入，不写入 `config.yaml`。代理用户名/密码初次写入 `data/config.yaml`；若轮换代理密码，必须同步修改该文件和 `.secrets`。默认本机代理为 `http://deploy:<代理密码>@127.0.0.1:7011`；控制 API 的 Secret 与此不同。

注意：容器间的 `127.0.0.1` 不相同。若 Sub2API 等其他容器需要通过 Mihomo 访问外网，必须单独配置共享 Docker 网络或可信的宿主机可达代理地址，不能直接使用它们各自容器的 `127.0.0.1:7011`。
