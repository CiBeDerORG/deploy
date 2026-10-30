# OpenHands Agent Canvas（Linux / fnOS）

使用官方 `ghcr.io/openhands/agent-canvas:latest` 镜像，一次部署 Canvas、Agent Server 和 Automation Server。
通过 deploy 的 Docker Compose 流程安装，不需要在宿主机安装 Node.js、uv 或桌面环境。

## 安装与更新

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh openhands install
# 后续更新：
sudo bash deploy.sh openhands update
```

首次访问：`http://<NAS-IP>:7016/canvas`。端口可在全局 `.env` 中修改。
如果该分支尚未合入 main，需要先切换到包含本功能的分支再执行以上命令。

## 统一配置

`<SOFTWARE_ROOT>/deploy/.env`（普通配置）：

```dotenv
OPENHANDS_IMAGE=ghcr.io/openhands/agent-canvas:latest
OPENHANDS_BIND_IP=0.0.0.0
OPENHANDS_PORT=7016
```

`<SOFTWARE_ROOT>/deploy/.secrets`（敏感配置）：

```dotenv
OPENHANDS_API_KEY=
```

`OPENHANDS_API_KEY` 是 deploy 包装层配置，传给官方容器的 `LOCAL_BACKEND_API_KEY`。**允许留空**，脚本首次安装自动生成并保存；更新和重复安装保留已有非空值。已配置的值不会被修改，可以包含引号、空格、特殊字符或非 ASCII 字符；需要明确首尾空白时使用外层引号。

在飞牛 NAS 上，密钥保存在 `/vol3/1000/software/deploy/.secrets`。可通过 `sudo nano /vol3/1000/software/deploy/.secrets` 查看或修改。不要上传该文件、转发密钥或在日志中公开。

默认绑定 `0.0.0.0` 便于内网 / EasyTier 浏览器访问，但必须使用 NAS 防火墙限制来源。部署强制设置 `AGENT_CANVAS_ALLOW_LAN_SESSION_KEY=false`，让非本机访问要求手动输入 API Key，而不是直接将密钥注入网页。**不建议裸露 HTTP 到公网**；远程访问请使用 VPN/EasyTier 或 HTTPS 反向代理以及网络访问控制。改成 `OPENHANDS_BIND_IP=127.0.0.1` 即可仅本机监听。

## 数据持久化与安全

| 宿主机路径 | 容器路径 | 用途 |
| --- | --- | --- |
| `<SOFTWARE_ROOT>/openhands/data` | `/home/openhands/.openhands` | Canvas 设置、对话历史及自动化数据 |
| `<SOFTWARE_ROOT>/openhands/workspace` | `/projects` | Agent 可访问、修改的项目代码 |

两个目录由安装器按上游 UID/GID 10001 创建。升级不删除数据，也不会递归更改已有项目文件的属主。如果工作区中的现有代码权限不足，请按项目单独调整权限。

Compose 只挂载这两个目录，不挂载宿主机 Docker Socket、不启用特权模式，也不使用 host 网络。Agent 仍可以在容器内运行命令、读写 `/projects`，不要将整个 NAS 根目录挂载进去。

## 状态与日志

```bash
sudo docker ps --filter name=openhands
sudo docker logs --tail 100 openhands
sudo docker inspect openhands --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}'
```

自动安装只提供 OpenHands Agent Canvas。若要在 Canvas 中使用 OpenCode ACP，可在页面中选择 OpenCode Agent；是否能启动还取决于容器内 CLI 与 npm 网络访问情况，需独立配置。模型提供商和自定义 API 可在 Canvas 的 LLM 设置中填写。

官方安装说明：https://docs.openhands.dev/openhands/usage/agent-canvas/setup
