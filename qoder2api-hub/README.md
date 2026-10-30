# Qoder2API Hub

基于 [shuishuipingan/qoder2api-hub](https://github.com/shuishuipingan/qoder2api-hub) 官方 GHCR 多架构镜像部署。它把 Qoder 国内版 / 国际版账号池封装为 OpenAI Chat Completions、Responses API 和 Anthropic Messages 兼容接口，并提供 Web 管理面板。

## 安装与更新

Linux / fnOS：

```bash
sudo bash deploy.sh env
sudo bash deploy.sh qoder2api-hub
sudo bash deploy.sh qoder2api-hub update
```

Windows 11（Docker Desktop）：

```powershell
.\deploy.ps1 env
.\deploy.ps1 qoder2api-hub
.\deploy.ps1 qoder2api-hub update
```

## 配置

- `.env`：`QODER2API_HUB_IMAGE`、`QODER2API_HUB_BIND_IP`、`QODER2API_HUB_PORT`。
- `.secrets`：可选 `QODER2API_HUB_API_KEY`；可选 `QODER2API_HUB_HTTP_PROXY`、`QODER2API_HUB_HTTPS_PROXY`、`QODER2API_HUB_ALL_PROXY`。代理 URL 可能含认证信息，因此只放在 `.secrets`。
- 默认镜像：`ghcr.io/shuishuipingan/qoder2api-hub:latest`，官方支持 `linux/amd64` 和 `linux/arm64`。
- 默认端口：`8790`；默认绑定 `127.0.0.1`，避免上游默认面板密码暴露到局域网。需要其他设备访问时，将 `QODER2API_HUB_BIND_IP` 改为 `0.0.0.0`，并先修改面板密码、限制防火墙来源。

API Key 留空时，容器以 `--lan` 模式启动，由上游首次启动自动生成。读取首次生成的 Key：

```bash
docker logs qoder2api-hub 2>&1 | grep -i "api key"
```

如需固定启动 Key，可填写 `QODER2API_HUB_API_KEY`；部署脚本不会擅自生成、覆盖或轮换该值。面板中启用 API Key 后，以面板当前配置的 Key 为准。

上游 Web 面板初始密码为 `admin`。首次登录后立即在「设置」中修改，不要将默认密码的管理面板直接暴露到公网。

## 数据持久化

```text
<SOFTWARE_ROOT>/qoder2api-hub/data/accounts/
<SOFTWARE_ROOT>/qoder2api-hub/data/usage/
```

`accounts/` 保存账号凭证、面板设置、API Key 和机器身份缓存；`usage/` 保存请求流水和用量汇总。安装和更新都不会删除这两个目录。

## API 地址

- OpenAI / Codex：`http://<服务器地址>:8790/v1`
- Claude Code / Anthropic：`http://<服务器地址>:8790`
- Web 管理面板：`http://<服务器地址>:8790/`

模型名称以面板和 `/v1/models` 返回的官方模型 ID 为准。客户端 API Key 使用上游面板「设置」中管理的 Key。

## 出口代理

可在 `.secrets` 设置 `QODER2API_HUB_HTTPS_PROXY`、`QODER2API_HUB_HTTP_PROXY` 或 `QODER2API_HUB_ALL_PROXY`。如果使用 deploy 项目中的 Mihomo，先创建网络并连接容器：

```bash
sudo bash deploy.sh proxy ensure
sudo bash deploy.sh proxy connect qoder2api-hub
```

Windows PowerShell 对应执行 `.\\deploy.ps1 proxy ensure` 和 `.\\deploy.ps1 proxy connect qoder2api-hub`。然后将代理 URL 配置为容器在 `proxy-net` 中可访问的地址。

## 更新行为

`update` 先拉取本次选定的镜像，再强制重建单个服务并等待 `/ping` 健康检查；镜像拉取失败时不会替换现有容器。GHCR 镜像遵循统一 `DOCKER_IMAGE_SOURCE` / `DOCKER_IMAGE_MIRRORS` 轮询配置。
