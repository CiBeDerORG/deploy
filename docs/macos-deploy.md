# macOS（Apple Silicon / Intel）通用安装入口

> `main` 已包含 macOS Docker Desktop 部署入口与原生 EasyHostAgent 安装入口；实际 Docker Desktop 文件共享和容器数据持久化仍需在目标 Mac 验证。

## 支持范围

| 命令 | macOS |
| --- | --- |
| `bash deploy.sh list` | 支持，列出各应用的安装支持状态 |
| `bash deploy.sh env` | 支持，首次初始化普通配置与密钥，后续仅补缺失键 |
| `bash deploy.sh <应用> sync` | 支持，复制部署资源但不覆盖 `data/state/workspace/backup/ssh/config` |
| `bash deploy.sh easynettopo install/update/uninstall` | Docker Desktop 模式，适配中；卸载只删除项目容器 |
| `bash deploy.sh portainer install/update/uninstall` | Docker Desktop 模式，适配中；需配置管理员密码与 Docker Socket |
| `bash deploy.sh easyhostagent install/update/uninstall/status/identity/pairing` | macOS ARM64 LaunchAgent、Docker Desktop 资源管理及应用市场安装/更新/卸载 |
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
git clone https://github.com/CiBeDerORG/deploy.git
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

配置文件权限为当前登录用户 `0600`，**绝不通过 `source .env` 执行配置内容**。部署互斥锁使用 macOS 原生 `lockf`。macOS 的 Docker Compose 安装/更新已复用 Linux/fnOS 的 `lib/image-sources.sh`，默认 `DOCKER_IMAGE_SOURCE=original`。如需 GHCR 加速站轮换，在 `/opt/software/deploy/.env` 中设置：

```dotenv
DOCKER_IMAGE_SOURCE=mirror
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
```

只有 `ghcr.io` 镜像才会转换到本轮加速站，非 GHCR（例如 Docker Hub）和 `easynettopo:local` 始终保持原样且不推进轮换。每次包含 GHCR 镜像的安装/更新选择一个站，`docker compose config/pull/up` 共用相同镜像地址；结果保存在 `<SOFTWARE_ROOT>/deploy/state/image-mirror.last`。切换回 `original` 不会修改轮换状态。与 Linux 一样，单次操作不会在某站拉取失败后自动尝试下一站；下次安装/更新才轮到下一个站。加速站可用性取决于所在网络，镜像拉取失败不会删除原有数据。卸载不读取镜像源配置，也不推进轮换。

Mac 版 EasyNetTopo 的 Compose override 使用当前用户 UID/GID，以便访问 Docker Desktop 共享的宿主机目录。真实文件共享行为依赖 Docker Desktop 版本和配置，必须在目标 Mac 上验证数据持久化与容器内写入。原 Linux/fnOS `deploy.sh` 路径与 systemd 安装逻辑保持不变。

## 验证范围

CI 在 GitHub 的 macOS Runner 上验证 Bash 3.2 语法、`list/env/sync`、目录和密钥权限、重复执行保持现有配置/数据，以及不支持的原生安装不会被启动。Docker Desktop 真正的镜像拉取与启动需在已安装 Docker Desktop 的目标机器进行验收；GitHub macOS Runner 的脚本校验**不等于真实 Docker Desktop 集成测试**。

## EasyHostAgent macOS 第一阶段（原生 LaunchAgent）

此功能已合并至 deploy 的 `main`；上游 EasyHostAgent 的 macOS 原生第一阶段与 Docker Desktop 第二阶段已一并合并至 `feat/deploy-manifest-lifecycle`。

**运行要求：** Apple Silicon 的 macOS；登录的普通图形会话用户；Bash 3.2、`curl`、`shasum`、`launchctl`、`plutil`、`file` 等系统工具；能访问 GitHub Release。第一阶段不依赖 Docker Desktop，但也不向控制端开放容器和应用商店接口。LaunchAgent **仅在该用户登录后**运行，不能保证注销后或未登录时继续运行。默认 HTTPS `0.0.0.0:7018` 可在可信 LAN 访问；应仅在防火墙放行受信任管理端，禁止直接公网暴露。

**配置：** `/opt/software/deploy/.env`，示例：

```dotenv
SOFTWARE_ROOT=/opt/software
EASYHOSTAGENT_RELEASE=v0.1.0-deploy-manifest-lifecycle.dev
EASYHOSTAGENT_MACOS_LOCAL_BINARY=
EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018
EASYHOSTAGENT_TRANSPORT=https
```

`EASYHOSTAGENT_MACOS_LOCAL_BINARY` 可指定来自可信编译源的 `darwin/arm64` 程序绝对路径，必须存在同名 `.sha256` 文件；留空时读取统一的 `EASYHOSTAGENT_RELEASE`，从同一个 GitHub Release 下载 macOS ARM64 资产并验证 SHA-256。Linux AMD64/ARM64 与 macOS ARM64 不再使用独立版本标签。

**密码与凭据：** Agent 没有需要手工填写的初始账号或固定密码。TLS 身份首次由本机程序生成，私钥保存在 `~/Library/Application Support/EasyHostAgent/identity.json`，0700 目录、0600 文件；一次性配对码由本机 CLI 生成，有效期 10 分钟，配对后的持久凭据由 Agent 私有数据目录维护。不会把配对码或 Token 写入部署模板。请在本机终端核对显示的公钥指纹，避免将配对码发到公开日志。

**安装、检查、配对、更新、卸载：**

```bash
# 当前开发分支（不要 sudo）
git clone -b feat/macos-easyhostagent-phase1-20261106 https://github.com/CiBeDerORG/deploy.git
cd deploy
sudo mkdir -p /opt/software
sudo chown "$(id -u):$(id -g)" /opt/software
bash deploy.sh env
bash deploy.sh easyhostagent install
bash deploy.sh easyhostagent status
bash deploy.sh easyhostagent identity
bash deploy.sh easyhostagent pairing
bash deploy.sh easyhostagent update
bash deploy.sh easyhostagent uninstall
```

`status` 调用 `launchctl print`。可在 Mac 本机执行 `curl -k https://127.0.0.1:7018/v1/health` 做简单可达性检查；`-k` **仅供本机诊断**，生产控制端必须按 Agent 公钥 SPKI 指纹校验证书。用户服务 plist 位于 `~/Library/LaunchAgents/org.cibeder.easyhostagent.plist`，二进制位于 `/opt/software/easyhostagent/native/bin/easyhostagent`，身份、配对信息、日志保存在上述用户私有数据目录。重新安装/更新不主动重置身份、配对或数据；卸载仅删除受管程序及 plist，默认保留数据目录与统一配置；不可逆数据清除需要自行单独确认。

当前 macOS 第一阶段的 `/v1/host/maintenance/update` 不提供远程自更新操作；请在 Mac 的受信任本机终端运行 `bash deploy.sh easyhostagent update`。第二、三阶段所需的 Docker 管理和商店安装接口当前故意不注册。

**验收限制：** GitHub Actions 原生 macOS 构建、HTTPS 与配对测试若成功，证明 macOS Runner 能运行；不等同于已验证你的 Mac mini 上的 launchd、文件权限、路由器访问及开机重登行为。须在目标机器补做实测。

## EasyHostAgent macOS 第二阶段：Docker Desktop 容器管理

macOS Docker Desktop 第二阶段已合并至 EasyHostAgent 的 `feat/deploy-manifest-lifecycle`，依赖第一阶段的 LaunchAgent、身份配对与主机概况能力。Linux AMD64/ARM64 和 macOS ARM64 共用 Release `v0.1.0-deploy-manifest-lifecycle.dev`。

与第一阶段相同，Agent 通过当前登录用户的 `LaunchAgent` 运行，并在默认 `0.0.0.0:7018` 上提供 HTTPS。第二阶段增加 Docker Desktop 的当前用户 Unix Socket（`~/.docker/run/docker.sock`）访问，不使用 Docker TCP、不要求 `sudo` 安装 Agent。Docker Desktop 可以未安装、未启动；此时 Agent 仍运行，Docker 列表返回不可用，不能将其视为容器已删除。

本阶段支持容器/Compose **已有实例**的发现、日志、CPU/内存按需统计，以及经过任务持久化、配对鉴权的启动/停止/重启；同时支持受信任应用源中的应用市场安装、更新和卸载。不支持 Docker 容器删除、Compose up/down/recreate、镜像拉取/项目重建或 macOS 强制更新。

**运行前检查：** Apple Silicon Mac、Docker Desktop 已安装且当前登录用户已启动（若需要 Docker 管理）；`docker info`、`docker compose version`、`ls -l "$HOME/.docker/run/docker.sock"` 均能正常执行。硬件 CPU/RAM 没有本脚本额外设定的最低门槛，以 Docker Desktop 官方要求和所运行容器的负载为准。需要从 EasyNetTopo 访问 Mac LAN IP 的 7018 端口，禁止直接暴露公网；当前登录用户退出时 LaunchAgent 不保证继续运行。

**配置与升级：** 使用 `/opt/software/deploy/.env`，保留所有已有其他配置与密钥，只需把原 macOS Release 一行改为：

```dotenv
EASYHOSTAGENT_RELEASE=v0.1.0-deploy-manifest-lifecycle.dev
EASYHOSTAGENT_MACOS_LOCAL_BINARY=
EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018
EASYHOSTAGENT_TRANSPORT=https
```

注意：`bash deploy.sh env` 不覆盖现存的 `.env`；请确保其中的 `EASYHOSTAGENT_RELEASE` 指向当前统一开发版。此前配置过独立 macOS Release 的旧值不再使用。本地可信安装包可设置 `EASYHOSTAGENT_MACOS_LOCAL_BINARY` 并提供同名 `.sha256`，不必从 GitHub 下载。Agent 不需要配置初始密码；本机自动生成身份与 TLS 私钥，私钥与配对信息留在 `~/Library/Application Support/EasyHostAgent` 的用户私有目录，不能复制到公共日志。

```bash
git clone -b feat/macos-docker-phase2-20261106 https://github.com/CiBeDerORG/deploy.git
cd deploy
bash deploy.sh env
# 确认 /opt/software/deploy/.env 中的 EASYHOSTAGENT_RELEASE 指向统一版本后：
bash deploy.sh easyhostagent install
bash deploy.sh easyhostagent status
bash deploy.sh easyhostagent identity
bash deploy.sh easyhostagent pairing
# 更新：保留身份和既有配对
bash deploy.sh easyhostagent update
# 卸载：保留用户私有数据与持久配对记录
bash deploy.sh easyhostagent uninstall
```

安装和更新仅在完成 SHA-256 核验、原生二进制检查和配置检查后替换程序；默认卸载不删除身份、配置、Docker 镜像、容器或卷，也不改变 Docker Desktop 本身。若需要不可逆清理数据，应另行人工评估与明确确认，本脚本不会自动清除。命令说明仅针对当前开发分支；实机 Docker Desktop 与本地网络访问仍需 Mac mini 验收。
