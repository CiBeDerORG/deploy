# EasyTier Automation Executor（独立手机执行器）

该业务独立于 `easytier` 主服务：从 `ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center` 拉取 `linux/amd64` 镜像，在 Linux / fnOS x86_64 上启动一个 Python/ADB/scrcpy/WebRTC 执行器。**OpenWrt ARM 不在此镜像支持范围内。**

通过根目录 `deploy.sh` 使用统一配置、GHCR 镜像源轮换和运行目录；不在本仓库编译执行器源码，也不修改原 EasyTier 部署、镜像、配置或容器。

## 安装

```bash
cd deploy
git pull
sudo bash deploy.sh env
# 普通配置：<SOFTWARE_ROOT>/deploy/.env
#   EASYTIER_EXECUTOR_CALLBACK_URL=http://<主服务可达IP>:7007（必填，以真实端口为准）
#   EASYTIER_EXECUTOR_BIND_IP=127.0.0.1（仅本机可访问；跨机需填写可信地址或 0.0.0.0 并限制防火墙）
#   EASYTIER_EXECUTOR_PORT=8766
# 敏感配置：<SOFTWARE_ROOT>/deploy/.secrets
#   EASYTIER_EXECUTOR_TOKEN=（首次安装留空则安全随机生成）
sudo bash deploy.sh easytier-automation-executor
```

**主镜像版本提示：** deploy 的 EasyTier 主程序默认标签目前仍是 `feat-node-attributes-main`，不是此自动化中心分支。若要部署本分支的首次配对/清理修复，请先在统一 `deploy/.env` 中显式设置 `EASYTIER_IMAGE=ghcr.io/cibederorg/easytier:feat-automation-center`，再运行 `sudo bash deploy.sh easytier update`。执行器仍单独使用 `EASYTIER_EXECUTOR_IMAGE=ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center` 并独立更新。更新脚本会提示本机检测到的旧标签，但不会私自覆盖主镜像配置，也不会清除 journal / ADB 密钥。

fnOS 默认运行位置为 `/vol3/1000/software/easytier-automation-executor/`，普通 Linux 默认 `/software/easytier-automation-executor/`。以当前 `SOFTWARE_ROOT` 为准。根安装器同步服务源码，不覆盖 `data/` 和全局密钥文件。

完成后在 **EasyTier 主服务 → 自动化中心 → 设置（管理员）** 填写从主服务可访问的执行器 URL：`http://<执行器IP>:8766`，并填写与 `deploy/.secrets` 中 `EASYTIER_EXECUTOR_TOKEN` **相同的值**，保存后点击“检查已保存连接”。这个检查只证明协议及认证可达，不等于 Android 配对成功或 WebRTC 视频已验收。

## 更新 / 仅同步

```bash
git pull
sudo bash deploy.sh env
sudo bash deploy.sh easytier-automation-executor update
# 或只把脚本同步到 SOFTWARE_ROOT，不触发镜像拉取、轮换和容器重启：
sudo bash deploy.sh easytier-automation-executor sync
```

`install` 与 `update` 都是幂等的期望状态操作：尚无执行器容器时，`update` 也会按首次安装继续，不需要先执行 `install`。如果发现历史运行记录或 ADB 密钥，但 `.secrets` 里 Token 为空，脚本会拒绝生成新 Token，要求恢复原凭据，避免破坏已有身份。

更新前在自动化中心关闭画面并完成/取消活动任务；重启不会自动重放旧动作。更新先完成 Compose 校验、镜像拉取和 amd64 架构检查，再重新创建容器。 脚本会先通过统一镜像源模块解析镜像、打印**本次实际拉取镜像**，再核对 Compose 解析结果一致才拉取。失败拉取不会中断已运行的容器。默认镜像地址可用 `EASYTIER_EXECUTOR_IMAGE` 指定完整 GHCR 标签或不可变的 `sha-<完整提交号>` 标签；`DOCKER_IMAGE_SOURCE=original|mirror` 和 `DOCKER_IMAGE_MIRRORS` 复用全局仅 GHCR 转换与每次执行轮换规则。

启用镜像加速，需要在**统一** `<SOFTWARE_ROOT>/deploy/.env` 中显式设置（默认 `original` 不会轮换）：

```dotenv
DOCKER_IMAGE_SOURCE=mirror
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
```

此配置对所有 Deploy 的 GHCR 项目生效，`install` 和 `update` 均轮换同一全局站点；例如本轮显示 `镜像来源：加速站 dockerproxy`、`本次实际拉取镜像：ghcr.dockerproxy.net/cibederorg/easytier-automation-executor:feat-automation-center`，下轮轮到 `ghproxy`。不会直接改写 `EASYTIER_EXECUTOR_IMAGE` 原始配置。


配置均集中在 `<SOFTWARE_ROOT>/deploy/.env` / `.secrets`。执行器自己不存储另一个独立 `.env`；令牌可首次自动生成并只写入权限为 0600 的 `.secrets`，再次安装和更新不会自动改掉已有 Token。启动前校验必填回调 URL、监听 IPv4、端口、任务限制和凭证。已存在其他项目持有的同名容器时拒绝接管。

## 持久化

```text
<SOFTWARE_ROOT>/easytier-automation-executor/
├── deploy/
│   ├── install.sh
│   ├── update.sh
│   └── docker-compose.yaml
└── data/                         # uid/gid 10001，私有权限
    ├── runtime/                  # SQLite journal / executor_id / 截图 artifacts
    └── adb/                      # ADB 配对授权私钥
```

Host 网络模式便于 WebRTC ICE 发布宿主机实际地址；只运行 **一个 Worker、一个容器**，不得将同一数据卷并发挂给多个执行器，也不暴露 ADB 5037 端口。监听默认是 `127.0.0.1:8766`；当主服务与执行器不是同一台宿主机时，需要在 `.env` 改 `EASYTIER_EXECUTOR_BIND_IP` 并通过可信私网/防火墙限制 API 访问，**不要把执行器直接裸露到公网**。回调 URL 由执行器访问主服务，方向与管理员页面所填的执行器 URL 相反。跨网络 WebRTC 还需验证 ICE/TURN/UDP 可达性。

注意：手动删除 `data/runtime` 会改变稳定执行器身份，不能据新执行器的回应推断旧任务已停止；删除 `data/adb` 可能需要重新配对手机。备份与迁移时同时保留两者和 Web 主服务自身数据库/密钥。

检查状态与日志：

```bash
docker ps --filter name=easytier-automation-executor
docker logs --tail=100 easytier-automation-executor
```

工作流和执行器源码：[EasyTier feat/automation-center / automation-executor](https://github.com/CiBeDerORG/EasyTier/tree/feat/automation-center/automation-executor)。镜像发布情况以 [独立执行器 GitHub Actions](https://github.com/CiBeDerORG/EasyTier/actions/workflows/automation-executor-image.yml) 为准。

## 自动化并行执行（feat/automation-center）

自动化中心脚本批量执行默认同时运行 **3 台**，单次运行可选择 **1～5 台**。执行器全局容量由统一 `deploy/.env` 的 `EASYTIER_EXECUTOR_MAX_RUNNING` 控制，默认 3，允许 1～5。不同脚本可同时使用不同设备；同一台设备仍按独占锁串行执行脚本动作，投屏是否可查看由媒体会话独立管理。执行记录的并行总览可按任务或设备查看，运行中的任务按进度同步；未知动作不会自动重放。

更新到新执行器镜像后，通过 `sudo docker exec easytier-automation-executor printenv AUTOMATION_MAX_RUNNING` 检查最终容器容量。**已有 .env 的显式值（例如 1 或 2）不会被部署脚本改写**；想使用默认三路并行，请把该值设为 3 后用 `sudo bash deploy.sh easytier-automation-executor update` 重建容器。更新前结束/取消活动脚本并关闭投屏，避免重建时出现未确认动作。

### 统一页面容量配置

升级 EasyTier 主程序与自动化执行器至包含「执行器容量」功能的版本后，管理员可在 **自动化中心 → 设置 → 执行器容量** 配置：同时运行手机数、待处理任务数、投屏会话数和投屏启动并发。这些配置直接发送给执行器并存储在执行器的数据卷 SQLite 中，**修改不需要再更改 .env 或重启容器**。新装执行器使用环境变量作为默认值；在页面保存过后，数据库中的配置优先生效。

默认建议依次为 **5 / 30 / 10 / 2**，不是强制上限；输入值只需是正整数。执行器运行并发默认仍为 3，建议根据实际 CPU、内存及 ADB 负载逐步增加。将限制调低不会中断已运行的动作，后续新任务会按较低容量排队。
