# 应用商店通用契约

新增应用只修改 Deploy 仓库。EasyNetTopo 读取固定 Git Commit 的定义、生成安装表单和候选包；EasyHostAgent 验证包、执行字段权限、写入主机配置并运行生命周期脚本。平台不按应用名称注册字段或图标，不增加定义管理页面。

## 仓库中的文件

```text
<应用>/
  app.yaml                     # schema_version: 2；元数据、运行方式、端口、生命周期、包文件
  config.yaml                  # 普通配置定义
  secrets.yaml                 # 密钥定义，默认值只能为空，禁止提交真实凭据
  assets/icon.svg              # 也支持 png、webp；单文件不超过 128 KiB
  deploy/
    docker-compose.yaml
    install.sh
    update.sh
    uninstall.sh
    config.env.example         # 自动生成，不手工维护
    config.secrets.example     # 自动生成，不手工维护
```

`app.yaml` 使用以下引用；安装包必须列出两份定义和两份生成模板，以及脚本实际使用的公共库。图标由控制端读取，不必下发主机。

```yaml
schema_version: 2
configuration:
  config: config.yaml
  secrets: secrets.yaml
icon: assets/icon.svg
```

两份定义都使用 `fields` 数组，字段的存储目标由所在文件决定，不再重复填写 `target`：

```yaml
fields:
  - key: APP_HTTP_PORT
    label: 访问端口
    custom_input: true
    type: port
    description: 应用在目标主机上的访问端口
    required: true
    default: 8080
    editable: true
```

- `custom_input` 必填：关闭时不提供页面输入；后端保留已有值，缺失时使用默认值。
- `editable` 默认 `true`：开启页面输入但设为 `false` 时显示只读字段。隐藏或只读字段不得由请求覆盖。
- `type` 支持 `string`、`number`（整数）、`boolean`、`port`、`ipv4`、`secret`。默认值必须符合对应类型；密钥类型只允许出现在 `secrets.yaml`。
- `label`、`description`、`required`、`default` 必填；继续支持已有上下限、长度和模式约束，不额外增加密码要求。
- `generated_by_script` 沿用现有安全生成契约：只有脚本确实生成并持久化可选密钥时才声明。必填、不可输入且没有默认值或生成机制的定义无效。
- 图标可省略，页面显示统一文字占位；声明后文件缺失、格式错误或含活动 SVG 内容会被拒绝。当前应用附带可替换的文字图标，不代表第三方官方标志。

维护 YAML 后执行：

```bash
python3 tools/validate_app_manifest.py --write-defaults --all
python3 tools/validate_app_manifest.py --examples --all
python3 -m unittest discover -s tests/contracts -p 'test_*.py'
```

该维护工具使用 PyYAML、jsonschema（与 CI 相同）；目标主机脚本使用生成模板，不新增 Python、YAML 解析器或 yq 运行依赖。CI 检查模板与定义完全一致。

## 主机配置与旧版本迁移

实际值位于 `<SOFTWARE_ROOT>/<应用>/config/.env` 和 `config/.secrets`，数据位于应用的 `data/`。文件按 0600 保存；仓库定义不是运行时配置。OpenCode 原生 `config/opencode.jsonc` 保留，首次补齐、更新不覆盖；维护组可编辑原生配置文件，部署凭据仍为 root 专属。

全局 `<SOFTWARE_ROOT>/deploy/.env` 保留软件根目录、时区、镜像源、共享访问地址等公共设置，其他未迁移服务继续使用原契约。新全局模板不再声明五个已迁移应用的专有键。已有全局文件不删除应用旧值：新应用文件缺失的字段才从旧文件导入，已有值（包括显式空值）优先；重试、更新及卸载不重置已有非空密钥。

仅迁移定义中声明的键，不复制其他应用的密钥。重复键、异常文件类型或符号链接安全失败。应用运行期原生配置与密钥默认随卸载保留。

## 安装、更新与卸载

先使用包含本契约的代码版本。发布顺序为：更新支持 v2 的 Agent、更新 EasyNetTopo，再刷新包含 v2 应用的 Git 来源。控制端会在传包前核对 Agent 支持的清单版本。v1 来源仍可读取，继续使用旧全局配置；不能把 v2 直接交给旧 Agent。

EasyNetTopo 中选择已配对主机和应用，点击安装，只填写显示且可编辑的预定义字段。定义、模板、脚本来自同一 Commit，并由包摘要和逐文件摘要绑定；密钥不写入目录数据库或响应日志。

Linux / fnOS CLI（将 `sub2api` 换成目标应用）：

```bash
sudo bash deploy.sh env
sudo bash deploy.sh sub2api sync
# 编辑 <SOFTWARE_ROOT>/sub2api/config/.env 和 .secrets 后：
sudo bash deploy.sh sub2api install
sudo bash deploy.sh sub2api update
sudo bash deploy.sh sub2api uninstall
```

`sync` 只同步文件并初始化缺失配置，不启动容器；安装与更新仍使用已有脚本。默认卸载只移除本应用容器/网络，不删除数据、配置、密钥或镜像，不执行数据清除。

Windows Docker 入口：

```powershell
.\deploy.ps1 env
.\deploy.ps1 sub2api sync
# 编辑 <SOFTWARE_ROOT>\sub2api\config\.env 和 .secrets 后：
.\deploy.ps1 sub2api install
.\deploy.ps1 sub2api update
```

PowerShell 沿用原入口支持范围，没有新增 `uninstall` 命令；卸载可在应用 `deploy` 目录执行 `docker compose down`，需要配置插值的应用先按其说明提供配置。Windows 密钥文件使用现有 ACL 保护；真实 Docker Desktop 和 ACL 行为须在 Windows 验收。

## 凭据与验收

Sub2API 的数据库、Redis、JWT、TOTP 密钥和 OpenCode 密码按现有脚本首次留空生成；Mihomo 的内核/API 与控制令牌沿用现有生成逻辑。Sub2API 缺省管理员凭据、Qoder2API 缺省 API Key 由上游首启处理。Portainer 管理员密码必须手工提供，沿用已有至少 12 字符检查；Sub2API 非空管理员密码沿用官方 8–72 UTF-8 字节检查。其他凭据不新增格式或复杂度要求。详情与访问端口见各应用 README。

生成的部署密钥保存在应用 `config/.secrets`。例如在私有终端只查看一个字段（结果不要分享或写入 CI）：

```bash
sudo sed -n '/^SUB2API_POSTGRES_PASSWORD=/p' /software/sub2api/config/.secrets
```

将 `/software` 换成实际软件根目录，fnOS 可能是 `/vol3/1000/software`。官方首启生成的管理员凭据按应用 README 的日志方法读取。

Docker 应用沿用清单声明的平台、架构及 Docker Engine / Compose v2 要求，不新增硬件最低配置。验收需覆盖新安装、旧全局配置迁移、同机两个应用隔离、更新保留凭据、卸载保留数据、旧 Agent 拒绝 v2、图标回退与只读字段。`docker compose -f <SOFTWARE_ROOT>/<应用>/deploy/docker-compose.yaml ps` 或 `docker ps` 可查看状态；真实安装、端口连通及 NAS/Windows 权限须单独验证，契约测试不代表真机部署通过。


## macOS 应用市场安装 / 更新 / 卸载

macOS Apple Silicon 主机使用当前登录用户的 Docker Desktop，不以 root 启动 EasyHostAgent。应用市场仍调用每个应用原有的 `deploy/install.sh`、`update.sh` 和 `uninstall.sh`，不另建一套容器生命周期接口。

- Agent 向脚本传入 `EASYHOSTAGENT_PLATFORM=macos`，并将 `DOCKER_HOST` 固定到当前用户的 Docker Desktop Unix Socket；PATH 包含 Docker Desktop 与 Homebrew 常见 CLI 目录。
- Linux / fnOS 仍按原契约要求 root；macOS 跳过仅为 Linux 主机准备的 root / chown 操作，配置文件由当前登录用户持有并保持 0600。
- 通过共享的 `deploy/lib/platform.sh` 处理 macOS 的 BSD `sed -i` 语法和权限差异。安装包仍使用同一 Compose 文件、镜像、配置字段和应用脚本。
- 目前应用清单中的五个 Docker Compose 应用声明支持 macOS ARM64；需先启动 Docker Desktop 并确认当前用户可以运行 `docker info` 与 `docker compose version`。

应用数据卷与配置的保留策略仍以各应用原有 `uninstall.sh` 为准；不会因 macOS 适配额外删除卷或数据。
