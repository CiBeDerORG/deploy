# GitHub Actions Runner

这个服务用于在 Linux 主机上安装并管理 GitHub Actions self-hosted runner。

## 目录

Runner 本体与运行数据保存在：

```text
<SOFTWARE_ROOT>/github-runner/data/runner
```

根 `deploy.sh` 同步服务文件时会保留 `data/`，因此更新 deploy 仓库不会覆盖 Runner 的注册信息和工作目录。

## 配置

先执行：

```bash
sudo bash deploy.sh env
```

然后分别编辑：

```text
<SOFTWARE_ROOT>/deploy/.env
<SOFTWARE_ROOT>/deploy/.secrets
```

普通配置 `.env`：

```dotenv
GITHUB_RUNNER_URL=https://github.com/<owner>/<repo>
```

敏感配置 `.secrets`：

```dotenv
GITHUB_RUNNER_TOKEN=<registration-token>
```

可选配置：

```dotenv
GITHUB_RUNNER_NAME=
GITHUB_RUNNER_LABELS=
GITHUB_RUNNER_GROUP=
GITHUB_RUNNER_USER=github-runner
GITHUB_RUNNER_PROXY=
```

说明：

- `GITHUB_RUNNER_NAME` 留空时默认使用当前主机名。
- `GITHUB_RUNNER_LABELS` 可填写逗号分隔的自定义 labels。
- `GITHUB_RUNNER_GROUP` 主要用于组织级 Runner。
- `GITHUB_RUNNER_PROXY` 仅用于安装/更新时访问 GitHub API 和下载 actions/runner；留空时直连。
- Runner 版本固定为 `latest`，安装/更新时自动获取 actions/runner 最新版本。
- Runner 工作目录固定为 `_work`。
- 当前支持 Linux `x64` 和 `arm64`。
- `GITHUB_RUNNER_TOKEN` 只在首次注册时需要。注册成功后可以从真实 `.secrets` 中清空。

注册 token 可在目标仓库的 GitHub 页面中进入：

`Settings -> Actions -> Runners -> New self-hosted runner`

获取。

如果服务器直连 GitHub 下载较慢，可在 `.env` 配置 Runner 专用代理：

```dotenv
GITHUB_RUNNER_PROXY=http://127.0.0.1:7890
```

也可以使用 curl 支持的其他代理 URL，例如：

```dotenv
GITHUB_RUNNER_PROXY=socks5h://127.0.0.1:7890
```

该变量只作用于 Runner 安装脚本中的 GitHub API 查询和 Runner 安装包下载，不会设置全局 `HTTP_PROXY` / `HTTPS_PROXY`。

## 安装

在 deploy 仓库根目录执行：

```bash
sudo bash deploy.sh github-runner
```

脚本会自动：

1. 创建独立系统用户 `github-runner`（可通过环境变量修改）。
2. 识别主机为 x64 或 arm64。
3. 自动获取并下载最新版本的官方 `actions/runner`。
4. 首次运行时注册 Runner。
5. 使用官方 `svc.sh` 安装 systemd 服务并启动。
6. 后续再次安装时保留已有 Runner 注册信息。

## 更新

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh github-runner update
```

更新会停止已有 systemd 服务，检查 Runner 最新版本，保留注册信息和工作目录，然后重新安装并启动服务。

## 查看状态

```bash
cd <SOFTWARE_ROOT>/github-runner/data/runner
sudo ./svc.sh status
```

也可以查看 Runner 目录中的 `.service` 文件获取实际 systemd service 名称。
