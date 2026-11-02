# EasyNetTopo 部署

从 deploy 仓库根目录运行以下命令。EasyNetTopo 和网关由同一个 Compose 项目管理。默认镜像 `ghcr.io/cibederorg/easynettopo:feat-docker-app-store` 由通用应用商店分支构建，支持 amd64 和 arm64。已有安装要切换到此版本时，先修改统一 `.env` 中的 `EASYNETTOPO_IMAGE`，再执行更新。

## 1. 配置文件

```bash
git switch feat/docker-app-store
sudo bash deploy.sh env
```

脚本会显示实际配置路径。以下是默认目录，已有统一配置时沿用原目录。

| 系统 | 普通配置 | 初始凭据 |
| --- | --- | --- |
| Linux | `/software/deploy/.env` | `/software/deploy/.secrets` |
| fnOS 使用 `/vol3/1000` 时 | `/vol3/1000/software/deploy/.env` | `/vol3/1000/software/deploy/.secrets` |

用 `sudoedit` 打开这两个文件，修改已有的同名行。相关普通配置的默认值如下。

```dotenv
TZ=Asia/Shanghai
EASYNETTOPO_HTTP_PORT=7017
EASYNETTOPO_IMAGE=ghcr.io/cibederorg/easynettopo:feat-docker-app-store
EASYNETTOPO_GIT_ALLOWED_HOSTS=github.com
EASYNETTOPO_GIT_ALLOW_HTTP=false
DOCKER_IMAGE_SOURCE=original
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
```

需要加速时，把 `DOCKER_IMAGE_SOURCE` 改为 `mirror`。安装和更新每次按公共轮换规则选一站。EasyNetTopo 的 GHCR 镜像使用该站，Docker Hub 的网关镜像 `caddy:2.10-alpine` 保留原地址。服务端原始镜像配置保留在 `.env`。可选加速站与使用限制见[仓库镜像源说明](../README.md)。

## 2. 运行要求

Linux 或 fnOS，amd64 或 arm64，运行中的 Docker Engine，支持 `up --wait`、`--pull never` 的 Docker Compose，以及 Bash、`flock` 和常用 Linux 工具。安装脚本使用 root，应用容器以 UID/GID `10001:10001` 运行。宿主机需要有空闲的本地端口，默认是 `127.0.0.1:7017`。其他设备访问时，可在宿主机配置 HTTPS 反向代理转发到该地址。

数据库及控制端状态保存在 `<SOFTWARE_ROOT>/easynettopo/data/`，私有 Git 源的 SSH 配置在 `<SOFTWARE_ROOT>/easynettopo/ssh/`，只读挂入容器。安装脚本会为新目录设置 `10001:10001`、权限 `0700`。对私有仓库，需要给该目录配置只读 SSH 凭据和经核对的 `known_hosts`。

## 3. 首次账号与密码

在 `.secrets` 中设置以下两项，均可留空。文件为 `root:root`，权限 `0600`。

```dotenv
EASYNETTOPO_ADMIN_USERNAME=admin
EASYNETTOPO_ADMIN_PASSWORD=
```

账号留空使用 `admin`。指定账号须为 3–32 个字符，以英文字母开头，后续可用字母、数字、下划线、点和连字符。指定密码须为 12–72 个 UTF-8 字节，支持空格、中文及标点，须能写在单行配置中。同名键只写一次。规则来自 [EasyNetTopo 管理员创建逻辑](https://github.com/CiBeDerORG/EasyNetTopo/blob/82df3cfabecf1b01186c19a7d439ab335c270e49/internal/storage/store.go) 和[一次性输入格式](https://github.com/CiBeDerORG/EasyNetTopo/blob/82df3cfabecf1b01186c19a7d439ab335c270e49/cmd/easynettopo/admin.go)。

数据库尚无管理员且密码留空时，脚本生成 48 位十六进制随机密码，先写回 `.secrets`，再通过标准输入初始化。已经有管理员时，重装或更新沿用原账号和密码。只在可信终端查看自动生成的密码，避免分享输出。

```bash
# Linux。fnOS 请将路径改为 /vol3/1000/software/deploy/.secrets
sudo sed -n 's/^EASYNETTOPO_ADMIN_PASSWORD=//p' /software/deploy/.secrets
```

## 4. 安装和检查

直接部署已发布镜像时，执行下方安装命令。要部署当前工作区版本，先在两仓库相邻的布局中，从 deploy 目录执行：

```bash
sudo docker build -t easynettopo:local ../EasyNetTopo
```

然后在 `.env` 中设置 `EASYNETTOPO_IMAGE=easynettopo:local`。此模式使用本机已构建的控制端镜像，网关仍由 Docker 拉取。

```bash
sudo bash deploy.sh easynettopo install
curl -fsS http://127.0.0.1:7017/api/v1/health
curl -fsS http://127.0.0.1:7017/api/v1/auth/status
```

健康接口成功且初始化状态含 `"initialized":true` 后，用配置的账号密码登录。调整端口后，检查命令也要使用新端口。

## 5. 卸载

```bash
sudo bash deploy.sh easynettopo uninstall
```

卸载移除本项目的容器及项目网络，保留数据库、Git SSH 配置、镜像和统一配置文件。重新安装可以沿用原数据。

## 6. 更新

```bash
sudo bash deploy.sh easynettopo update
```

更新保留数据库及凭据。使用 `easynettopo:local` 时，先用最新工作区源码重新运行本地构建命令，再执行更新。
