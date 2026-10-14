# Mihomo

部署 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 官方内核。默认普通 Docker bridge 模式，**不开 TUN、不接管宿主机网络**。混合 HTTP/SOCKS5 代理宿主机端口 `7011`，控制 API `7012`；容器内部仍为 7890 / 9090。

## 配置和安装

```bash
sudo bash deploy.sh env
# 按需编辑 <SOFTWARE_ROOT>/deploy/.env / .secrets
sudo bash deploy.sh mihomo
sudo bash deploy.sh mihomo update
```

`.env`：`MIHOMO_MIXED_PORT=7011`、`MIHOMO_API_PORT=7012`、`MIHOMO_PROXY_BIND_IP=127.0.0.1`、`MIHOMO_API_BIND_IP=127.0.0.1`。`.secrets`：`MIHOMO_API_SECRET`（留空首次自动生成）、`MIHOMO_PROXY_USER=deploy`、`MIHOMO_PROXY_PASSWORD`（留空首次自动生成）。

首次安装从 `deploy/config.example.yaml` 生成 `<SOFTWARE_ROOT>/mihomo/data/config.yaml`，附加初始代理用户名和密码；**后续不会覆盖用户配置**。添加代理节点、订阅、代理组或规则请直接修改运行目录中的 `data/config.yaml`，并执行 `sudo bash deploy.sh mihomo update` 做语法测试及重建。初始规则 `MATCH,DIRECT` 是供部署验证的空白配置，不会凭空提供境外代理。

API 密钥通过 Mihomo 官方 `CLASH_OVERRIDE_SECRET` 环境变量传入，修改 `.secrets` 后更新服务即可生效。代理认证写入首次生成的 `data/config.yaml`；如需轮换代理密码，请同时更新该文件及 `.secrets`，避免两处不一致。运行数据为 root 访问受限目录，不提交 Git。

浏览器面板由 Mihomo 的 `external-ui-url` 下载 MetaCubeXD 静态资源，成功下载后使用 `http://127.0.0.1:7012/ui`（控制 API 需要密钥）。如网页在远程机器上使用，可通过 SSH 隧道访问，不建议把控制口直接发布到公网。外网或 EasyTier 设备需要连接代理时，先设置强代理认证并用防火墙仅放行可信 IP，才将 `MIHOMO_PROXY_BIND_IP` 改为 `0.0.0.0`；控制口仍建议保持回环地址。默认本地地址：`http://deploy:<密码>@127.0.0.1:7011`。

注意：容器间的 `127.0.0.1` 并不相同。其他 Docker 容器要访问 Mihomo，应采用明确的共享网络，或按安全策略启用宿主机可达的绑定地址；不要把另一个容器的代理设置直接写成 `127.0.0.1:7011`。
