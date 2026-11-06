# macOS（Apple Silicon / Intel）通用安装入口

> 开发适配分支：`feat/macos-deploy-entry-20261106`。当前仅保证已列明的 Docker Desktop 应用按独立入口执行；这不是 macOS 原生 EasyHostAgent 支持。

## 支持范围

| 命令 | macOS |
| --- | --- |
| `bash deploy.sh list` | 支持，列出各应用的安装支持状态 |
| `bash deploy.sh env` | 支持，首次初始化普通配置与密钥，后续仅补缺失键 |
| `bash deploy.sh <应用> sync` | 支持，复制部署资源但不覆盖 `data/state/workspace/backup/ssh/config` |
| `bash deploy.sh easynettopo install/update/uninstall` | Docker Desktop 模式，适配中；卸载只删除项目容器 |
| `bash deploy.sh portainer install/update/uninstall` | Docker Desktop 模式，适配中；需配置管理员密码与 Docker Socket |
| `bash deploy.sh easyhostagent install` | **不支持**：当前为 Linux / fnOS systemd 原生服务 |
| 其他应用的 `install/update/uninstall` | 暂不支持，明确报错，不调用 Linux 原生脚本 |

## 运行要求

- macOS 自带 Bash 3.2、`rsync`、`lockf` 即可运行 Mac 安装入口，不需要额外安装 GNU sed、flock 或 Bash 5。
- 需要已安装并启动 Docker Desktop，且 Docker Compose v2 可用。**不要在 Mac 上使用 sudo 运行部署命令**：Docker Desktop 绑定当前登录用户的 Docker Context。
- 默认与 Linux 统一使用 `/opt/software`。首次配置前，手工授权该目录给当前用户：

```bash
sudo mkdir -p /opt/software
sudo chown "$(id -u):$(id -g)" /opt/software
```

- 在 Docker Desktop → Settings → Resources → File Sharing 中确保 `/opt/software` 可被共享。Portainer 必须另外在 Docker Desktop → Settings → Advanced 中启用默认 `/var/run/docker.sock`；未启用时安装会提前中止。Docker Desktop 的 Docker Engine 位于 Linux 虚拟机内，所以 Mac 上的 Agent 容器不能天然管理 macOS 宿主机进程、LaunchAgents 或硬件状态。

## 使用

```bash
# 克隆（或切换到已合并的主分支）
git clone -b feat/macos-deploy-entry-20261106 https://github.com/CiBeDerORG/deploy.git
cd deploy

# 初始化安全的配置文件（只需首次）
bash deploy.sh env

# 查看哪些服务能在 Mac 安装
bash deploy.sh list

# EasyNetTopo
bash deploy.sh easynettopo install
bash deploy.sh easynettopo update
bash deploy.sh easynettopo uninstall

# Portainer：首次可留空，安装器自动生成管理员密码并保存到 config/.secrets；也可预先填写自定义密码
bash deploy.sh portainer install
bash deploy.sh portainer update
bash deploy.sh portainer uninstall
```

Portainer 首次安装如未设置密码，会使用安全随机源生成 48 位十六进制管理员密码，写入受保护的 `/opt/software/portainer/config/.secrets`；已有非空值不会被轮换。旧版统一 `deploy/.secrets` 的非空密码优先作为迁移来源。EasyNetTopo 首次初始化会自动生成随机管理员密码并保存于统一 `deploy/.secrets`，不会输出密码到日志。

配置文件权限为当前登录用户 `0600`，**绝不通过 `source .env` 执行配置内容**。部署互斥锁使用 macOS 原生 `lockf`。默认保持 `DOCKER_IMAGE_SOURCE=original`；当前 Mac 入口遇到镜像源 `mirror` 会明确拒绝，暂未移植 GHCR 镜像轮换。安装与更新将拉取镜像；无法连接仓库时会失败但保留原有数据。

Mac 版 EasyNetTopo 的 Compose override 使用当前用户 UID/GID，以便访问 Docker Desktop 共享的宿主机目录。真实文件共享行为依赖 Docker Desktop 版本和配置，必须在目标 Mac 上验证数据持久化与容器内写入。原 Linux/fnOS `deploy.sh` 路径与 systemd 安装逻辑保持不变。

## 验证范围

CI 在 GitHub 的 macOS Runner 上验证 Bash 3.2 语法、`list/env/sync`、目录和密钥权限、重复执行保持现有配置/数据，以及不支持的原生安装不会被启动。Docker Desktop 真正的镜像拉取与启动需在已安装 Docker Desktop 的目标机器进行验收；GitHub macOS Runner 的脚本校验**不等于真实 Docker Desktop 集成测试**。
