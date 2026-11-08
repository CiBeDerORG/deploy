# EasyNetTopo 部署

从 deploy 仓库根目录运行以下命令。EasyNetTopo 使用单个 Go 容器直接提供前端页面和 HTTP API，不再依赖 Caddy 网关。默认镜像 `ghcr.io/cibederorg/easynettopo:feat-deploy-manifest-lifecycle` 由应用生命周期开发分支构建，支持 amd64 和 arm64。镜像标签统一取自本仓库根目录的真实 `versions.env`；安装/更新自动同步该文件，不再从用户 `.env` 接收镜像版本。

## 1. 配置文件

```bash
git switch main
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
EASYNETTOPO_BIND_IP=0.0.0.0
EASYNETTOPO_GIT_ALLOWED_HOSTS=github.com
EASYNETTOPO_GIT_ALLOW_HTTP=false
DOCKER_IMAGE_SOURCE=original
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
```

需要加速时，把 `DOCKER_IMAGE_SOURCE` 改为 `mirror`。安装和更新按公共轮换规则为 EasyNetTopo 的 GHCR 镜像选择加速站；不再拉取 Caddy 镜像。原始镜像由仓库 `versions.env` 统一指定。可选加速站与使用限制见[仓库镜像源说明](../README.md)。

## 2. 运行要求

Linux 或 fnOS，amd64 或 arm64，运行中的 Docker Engine，支持 `up --wait`、`--pull never` 的 Docker Compose，以及 Bash、`flock` 和常用 Linux 工具。安装脚本使用 root，应用容器以 UID/GID `10001:10001` 运行。容器内 Go 进程通过 `EASYNETTOPO_ALLOW_CONTAINER_BIND=true` 显式允许监听 `0.0.0.0:8080`；宿主机发布地址由统一 `.env` 的 `EASYNETTOPO_BIND_IP` 控制：设置 `0.0.0.0` 时监听所有 IPv4 网卡，局域网及具备网络路由/防火墙放行条件的远端设备可以用服务器真实 IP 的 `7017` 端口访问；设置 `127.0.0.1` 时只允许宿主机本地访问。**0.0.0.0 不代表只开放内网，也不代表自动获得公网访问权限。当前服务直接提供 HTTP，账号密码会经明文链路传输，严禁无保护地暴露公网；请通过防火墙限制可信来源，并为公网入口配置 HTTPS 反向代理。**

数据库及控制端状态保存在 `<SOFTWARE_ROOT>/easynettopo/data/`，私有 Git 源的 SSH 配置在 `<SOFTWARE_ROOT>/easynettopo/ssh/`，只读挂入容器。安装脚本会为新目录设置 `10001:10001`、权限 `0700`。对私有仓库，需要给该目录配置只读 SSH 凭据和经核对的 `known_hosts`。

## 3. 首次账号与密码

在 `.secrets` 中设置以下两项，均可留空。文件为 `root:root`，权限 `0600`。

```dotenv
EASYNETTOPO_ADMIN_USERNAME=admin
EASYNETTOPO_ADMIN_PASSWORD=
```

账号留空使用 `admin`，密码留空时首次安装自动生成。**不再对管理员账号或密码施加字母开头、字符种类或自定义长度限制**：短密码、中文、空格、标点和长密码均可原样使用。Go 后端使用完整密码的 SHA-256 摘要再交给 bcrypt 计算哈希，以规避 bcrypt 原生 72 字节输入上限，同时兼容旧版 bcrypt 密码哈希。`.secrets` 采用单行 `KEY=VALUE` 格式，因此账号和密码须分别写在单行内；不要在日志中展示凭据。同名键只写一次。登录 HTTP 请求及本地初始化通道均有 1 MiB 的传输体积保护，不属于密码复杂度限制。

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

然后仅用于开发测试时，将仓库 `versions.env` 的 `EASYNETTOPO_IMAGE` 改为 `easynettopo:local`（不要修改统一 `.env`）。此模式只使用本机已构建的控制端镜像，不再拉取网关。

```bash
sudo bash deploy.sh easynettopo install
curl -fsS http://127.0.0.1:7017/api/v1/health
curl -fsS http://127.0.0.1:7017/api/v1/auth/status
```

健康接口成功且初始化状态含 `"initialized":true` 后，用配置的账号密码登录。调整端口后，检查命令也要使用新端口。若配置 `EASYNETTOPO_BIND_IP=0.0.0.0`，同网段设备可尝试访问 `http://<服务器内网IP>:7017`，实际连通性仍取决于服务器及云平台防火墙。部署完成后可用 `sudo docker ps -a --filter name=easynettopo` 核对：正常情况下只有 `easynettopo` 容器。

**从旧版双容器升级**：更新 `deploy` 仓库及 EasyNetTopo 发布镜像后，直接执行上面的安装命令或下面的更新命令。安装脚本通过 `docker compose up --remove-orphans` 仅清理由本项目管理的旧 `easynettopo-gateway` 容器；不会清除数据库、SSH 配置或管理员密码。若使用自建 `easynettopo:local` 镜像，必须先根据最新 EasyNetTopo 源码重新构建（旧镜像不支持单容器监听授权）。

## 5. 卸载

```bash
sudo bash deploy.sh easynettopo uninstall
```

卸载移除 EasyNetTopo 容器、项目网络以及可能残留的旧版 Caddy 网关容器，保留数据库、Git SSH 配置、镜像和统一配置文件。重新安装可以沿用原数据。

## 6. 更新

```bash
git pull --ff-only origin main
sudo bash deploy.sh easynettopo update
```

从最新 deploy 运行更新，会自动读取仓库 `versions.env` 的镜像版本并同步到软件目录；旧 `.env` 的 `EASYNETTOPO_IMAGE` 字段会被忽略，不会覆盖仓库版本。更新保留数据库及凭据，并按当前 `.env` 中的 `EASYNETTOPO_BIND_IP` 重新绑定宿主机端口。GitHub Actions 发布的默认 GHCR 分支镜像无需在目标机器编译，更新命令会直接重新拉取；如选用自建 `easynettopo:local`，则需自行更新该镜像。
