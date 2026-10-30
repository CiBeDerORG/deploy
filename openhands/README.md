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

## 卸载

在 `deploy` 仓库根目录执行：

```bash
sudo bash deploy.sh openhands uninstall
```

该命令只移除 OpenHands Compose 容器及其专属网络，**不会删除**统一配置、API Key、镜像、项目代码或历史会话，便于后续重新安装。若不再需要数据，确认已备份重要工作目录并确认容器已卸载后，才可执行以下不可恢复的清理操作（fnOS 默认安装路径）：

```bash
sudo rm -rf -- /vol3/1000/software/openhands/data
sudo rm -rf -- /vol3/1000/software/openhands/workspace
```

上述两条命令会永久删除聊天、自动化状态和可能包含项目源代码的工作区。不要在未检查目录内容时直接执行，统一 `deploy/.secrets` 中的密钥不会随服务卸载被删除。

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

默认绑定 `0.0.0.0` 便于内网 / EasyTier 浏览器访问，但必须使用 NAS 防火墙限制来源。部署强制设置 `AGENT_CANVAS_ALLOW_LAN_SESSION_KEY=false`，不会直接把密钥注入网页；同时把同一个 `OPENHANDS_API_KEY` 传给 `LOCAL_BACKEND_API_KEY` 和 `OH_SESSION_API_KEYS_0`，确保 Agent Server API 真正验证密钥，绕过上游 Docker entrypoint 已确认的问题 [OpenHands #17763](https://github.com/OpenHands/OpenHands/issues/17763)。

**API Key 不是网页的用户名/密码登录**：首次打开可能显示公开的 Canvas 页面，使用本地 Agent 时会提示输入 API Key；如当前浏览器曾输入过，浏览器可能保存并复用密钥。无密钥调用 `/api/conversations/search` 应返回 HTTP 401；部署脚本在安装/升级时检查匿名请求为 401、携带正确 Key 的请求为 200，鉴权异常则停止该服务。**网页能加载本身不能证明已通过身份验证**。

可用以下命令检查当前运行容器（只打印 HTTP 状态，不会打印密钥）：

```bash
sudo docker exec openhands node -e 'fetch("http://127.0.0.1:8000/api/conversations/search").then(r=>{console.log("匿名 API HTTP:",r.status);process.exit(r.status===401?0:1)}).catch(()=>process.exit(1))'
```

还需要真正的**整站登录页**时，应在 OpenHands 前面增加带认证的 HTTPS 反向代理，例如 Authelia/oauth2-proxy；API Key 不等同于 Web 管理员账户。**不建议裸露 HTTP 到公网**；远程访问请使用 VPN/EasyTier 或 HTTPS 反向代理以及网络访问控制。改成 `OPENHANDS_BIND_IP=127.0.0.1` 即可仅本机监听。

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
