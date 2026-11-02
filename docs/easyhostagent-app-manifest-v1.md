# EasyHostAgent 应用商店 `app.yaml` v1 标准

> 状态：**T00-03 协议定义**，不是完整运行时实现。  
> 日期：2026-10-27  
> 单一机器可读 Schema：[`schema/app-manifest-v1.schema.json`](../schema/app-manifest-v1.schema.json)（JSON Schema Draft 2020-12）。  
> 契约示例：[`portainer`](../schema/examples/portainer.app.yaml)、[`sub2api`](../schema/examples/sub2api.app.yaml)。示例**不等于正式发布的应用 manifest**；T03-02/T03-03 才把文件分别放入 `portainer/app.yaml` 和 `sub2api/app.yaml`。  
> 相关 Agent API：[EasyHostAgent OpenAPI v1](https://github.com/CiBeDerORG/EasyHostAgent/blob/main/docs/api/openapi-v1.json)。

## 一、目录规则及三端责任

```text
Deploy/                             ← 仅 EasyTier 中央管理端 git clone/pull
├── schema/
│   ├── app-manifest-v1.schema.json   ← 本次新增
│   └── examples/                    ← 本次新增：协议测试示例
├── portainer/
│   ├── app.yaml                     ← T03-02 才会添加
│   └── deploy/
│       ├── docker-compose.yaml
│       ├── install.sh
│       └── update.sh
├── sub2api/
│   ├── app.yaml                     ← T03-03 才会添加
│   └── deploy/
│       ├── docker-compose.yaml
│       ├── install.sh
│       ├── update.sh
│       └── lib.sh
├── lib/image-sources.sh
├── .env.example
└── .secrets.example
```

1. EasyTier **只在用户点击“刷新商店”时**更新自己的 Deploy 工作副本；普通浏览不触发拉取，也不让 Agent 访问 GitHub。
2. EasyTier 读取各应用 `<app-id>/app.yaml`，通过 JSON Schema + 后述跨字段/脚本/路径检查，构建商店索引。
3. 安装时按 `package.files` **白名单**从固定 Git commit 取出指定应用文件及共享依赖，生成不可变部署包，附带经过验证的 manifest、来源 commit、SHA-256。当前版本不规定 tar/zip 的确切封装形式，这由 T03-07 统一固定。
4. Agent 只接收包并核对摘要、Agent 授权、指定目标目录及解包安全性，然后执行声明的动作；**不接收用户任意 Shell 命令/路径**。
5. 部署包文件的 `destination` **相对于宿主机 `SOFTWARE_ROOT`**；`source` **相对于中央 Deploy 仓库根目录**。如 `sub2api/deploy/lib.sh` → `sub2api/deploy/lib.sh`，`lib/image-sources.sh` → `deploy/lib/image-sources.sh`。
6. 宿主机唯一共享配置仍在 `<SOFTWARE_ROOT>/deploy/.env`、`<SOFTWARE_ROOT>/deploy/.secrets`；Agent 负责保留现值、原子修改和并发互斥，**配置文件本身和运行数据绝不可跟随包被覆盖**。

## 二、字段定义

| 字段 | 类型 | 含义/约束 |
|---|---|---|
| `schema_version` | integer=1 | 标准版本，未知版本拒绝 |
| `id` | slug | 全局唯一，必须与 Deploy 应用目录名一致，同一主机最多一个受管实例 |
| `name`, `summary` | string | 商店显示名称、简述 |
| `category`, `homepage` | enum/string | 分类及可选主页 |
| `runtime` | object | 本期仅 `kind: docker_compose`；声明 `compose_project`、`compose_file`、`requires_root` |
| `compatibility` | object | `platforms` 为 `linux/fnos`，`architectures` 为 `amd64/arm64`，Docker、Compose v2 必需 |
| `package.files` | array | 每个成员必须给 `source`/ `destination`，可选文件模式 `0644/0755`；没有隐藏文件的自动递归拷贝 |
| `config` | array | 声明每个表单字段的 key、显示标签、类型、必填、目标配置文件、可选默认值与校验约束 |
| `ports` | array | 按顺序声明服务端口、`purpose:web/other`、协议、宿主机端口配置键、容器端口与 Compose 服务名 |
| `actions` | object | install 必填，update/uninstall 可选；`script` 或 `compose_down`；路径必须出现在 package 文件清单中 |
| `verification` | object | `required_services` 必须存在于 Compose；验收为 running / healthy，附超时 |
| `data` | object | 数据文件根目录、已归属命名卷、卸载默认保留数据 `default_retain: true` |

### 2.1 `config` 字段

支持类型：`string`、`number`、`boolean`、`port`、`ipv4`、`secret`。

- 普通字段固定落地至 `deploy/.env`；`secret` 必须写入 `deploy/.secrets`，不得明文回显或记录执行日志。
- key 必须匹配大写环境变量规范；**同一 manifest 不得重复 key**。
- `default` 对普通字段可为字符串/整数/布尔，对 secret **最多只能是空字符串**，不允许在私有仓库中提交真实密码。
- `required: true` 且无默认值时，表单必须提示输入；选填且 `default: ""` 表示留空，不是自动生成。
- `generated_by_script: true` 表示 Deploy 安装脚本能为首次空值生成并持久化敏感值；**Agent 不生成，也不得在更新时重新随机生成已存在的值**。
- 更新时对已存在的用户值必须保留；新增字段才采用 manifest 默认值。对实际 `install.sh` 中未支持的变量，不得仅靠 manifest 虚构可修改能力。
- `min_length` / `max_length` 的字符串度量单位需与应用原脚本一致；Sub2API 首次管理员密码以 **UTF-8 字节长度 8–72** 为准，单靠 JSON Schema 的字符长度不足以验证字节数，T03-01/T04-04 要补原生值校验。

### 2.2 端口与服务

- 遍历 `ports`：存在 Web 端口则选**第一个** Web 端口作为 EasyTier 自动关联的主要服务；不存在 Web 则选列表第一个其他端口；无端口则不创建服务。
- `host_port_key` 必须引用当前 manifest 的、类型为 `port` 的 config 字段；`bind_address_key`（若存在）必须引用 `ipv4` 类型。
- `container_port` 必须与 Compose 对应服务的内部监听端口一致；`service` 必须是 Compose `services` 的名称。
- 端口变化后 EasyTier 更新已关联服务及其公网映射的**目标端口**，保持公网绑定端口不变。这里由 EasyTier 资产模块执行，Agent 不修改网络拓扑数据库。
- **自动关联不等于自动公开公网**；公网发布必须保留既有显式授权流程。

### 2.3 `actions` 规范

- `strategy: script`：必须指定**相对于应用目录**的 `path`，且对应 `package.files.destination` 必须正好是 `<id>/<path>`。Agent 不接受调用方指定脚本参数或其他任意执行命令；只执行可信 manifest 定义的脚本与允许的固定参数。
- `strategy: compose_down`：通过已验证的 Compose 项目和 `runtime.compose_file` 执行正常 `docker compose down`；禁止自动添加 `-v` 或尝试回滚。遇到 Docker 同名但不属于该受管实例的资源，必须拒绝，不能静默接管。
- 在已有 Git 源上架新应用时，把 `app.yaml` 放在仓库根目录的 `<应用ID>/` 下，把 Compose 文件、脚本和共享依赖列入 `package.files`。普通参数和敏感参数分别在仓库根的 `.env.example`、`.secrets.example` 登记键名。没有参数时，模板可仅包含说明注释。商店使用清单生成表单，Agent 执行时写入实际值。
- 商店安装使用 `script`。卸载可用现有的 `compose_down`，也可在包内声明独立的卸载脚本。安装和卸载共用一个脚本时，声明 `uninstall: {strategy: script, path: deploy/install.sh, argv: [uninstall]}`。脚本应只移除本项目服务，保留数据和配置；命令参数不能取自网页输入。
- `update` 缺失时商店标记不可更新；`uninstall` 缺失时不能冒充支持卸载。基础 start/stop/restart 由 Docker 适配器统一实现。
- 错误时留存日志和现场：**不自动回滚镜像、配置、容器或数据**。任务失败状态必须可见并且不可作为“卸载成功”触发服务删除。

### 2.4 验证与数据保护

- `verification.required_services` 必须真实存在于 Compose；`state: running` 要求目标容器都在运行，`healthy` 要求必要的健康检查达到健康或按照已固定的服务策略检查通过。若未达到，在规定时间内等待，最终失败但保留 Docker 现场和日志。
- `data.paths` 是相对 `SOFTWARE_ROOT` 的**可保护用户数据根目录**，必须与真实 Compose 挂载的宿主机数据目录核对；不包含 `docker.sock` 或未被应用单独拥有的系统目录。
- 默认卸载保留数据；选择彻底删除时需要两次显式确认，且只能处理明确归属的目录/卷，不随 Compose down 自动做 `--volumes`。
- 重新安装时如检测到历史目录，用户选择复用旧数据或全新安装；后者的目标目录必须隔离，**不能无意覆盖原数据**。

## 三、跨字段/仓库验证（JSON Schema 外仍必须检查）

T03-01 的解析器必须在加载 manifest 后依次执行：

1. **目录与身份**：`id == 目录名`、文件相对路径规范、所有 `package.files.source` 在目标 Git commit 下确实存在且为普通文件。
2. **落点隔离**：`destination` 仅能位于 `<id>/...` 或允许的 `deploy/lib/...` 共享模块；不允许覆写 `deploy/.env`、`deploy/.secrets`、任何 `data/`、`state/`、`backup/`、`workspace/`、`runtime/`。禁止软链接、硬链接、设备文件、绝对路径及 `..` 路径穿越。
3. **映射冲突**：`source` / `destination` 无重复，文件名大小写不造成目标冲突；单包大小及文件数不超限制。
4. **动作依赖**：`actions.*.path` 对应打包文件；Compose 文件在包内；`script` 只允许声明的执行路径，`argv` 只允许固定白名单值而非调用方任意注入。
5. **Compose 一致性**：验证 `runtime.compose_project` 与 Compose 的 `name:`；检查 `ports.service`、`ports.container_port`、`verification.required_services`、宿主机绑定端口变量与 Compose 模板引用一致。
6. **变量一致性**：`config` key 唯一，`ports.host_port_key`、`bind_address_key` 所引用变量存在且类型正确；秘密不得出现在普通 env；生成型 secret 必须在脚本中有确实实现。
7. **安全执行**：manifest 来源应限定为用户授权的中央 Deploy 工作副本固定 commit；所有资源归属显式确认。**JSON Schema 校验成功不代表脚本可安全执行**。
8. **不可变版本**：商店索引记录 Git commit SHA 与 manifest 内容 SHA；Agent 接收的部署包内 metadata/应用 ID 必须与提交任务中的目标应用匹配，不允许换包/错包。
9. **系统兼容**：`platforms` 和 `architectures` 只是准入规则，实际目标设备 Docker/Compose/端口/数据目录占用还需安装前即时校验。
10. **错误处理**：上述任何检查失败时拒绝发布到可安装商店，给出路径及原因；**不能使用部分有效 manifest 自动安装**。

## 四、与当前 Deploy 源码逐项对应

| 现有源码 | 本标准怎样映射 |
|---|---|
| `portainer/deploy/docker-compose.yaml` | `runtime.compose_project: portainer`，Web 容器端口 9000，宿主机配置 `PORTAINER_HTTP_PORT` |
| `portainer/deploy/install.sh` | 使用 `SOFTWARE_ROOT/deploy/.env` 与 `.secrets`；Portainer 管理密码 `PORTAINER_ADMIN_PASSWORD` 是必填 secret 且至少 12 字符 |
| `portainer/deploy/update.sh` | 包装 install.sh update；以 `actions.update` 脚本声明，不能仅因为脚本存在就假定可以回滚 |
| `sub2api/deploy/docker-compose.yaml` | 一个 Compose Project 同时含 `sub2api`、`postgres`、`redis`；Web 映射 host `SUB2API_HTTP_PORT` → 8080 |
| `sub2api/deploy/install.sh` | PostgreSQL、Redis、JWT、TOTP 4 个 secret 缺失时脚本自动生成，不轮换已存在密码；健康验证应覆盖三服务 |
| `sub2api/deploy/lib.sh` | 必须作为应用内依赖一起打包，否则 install.sh 无法执行 |
| `lib/image-sources.sh` | 必须按 `lib/image-sources.sh` → `deploy/lib/image-sources.sh` 放置，否则 Sub2API 镜像源逻辑可能找不到 |
| `.env.example`、`.secrets.example` | 用于 Agent 全局配置初始化的默认参考源，不是应用目录覆盖文件；必须保留共享现值 |
| `deploy.sh` `run_task` | 原 CLI 继续可用，本期 GUI Agent 只按 manifest 的脚本及部署目录协议操作；不要求在所有宿主机安装整个 Deploy 仓库 |

**重要区别**：Portainer 示例 `portainer/data`、Sub2API 示例 `sub2api/data/*` 是保护/归属声明，不等于此版本实现了彻底删除数据动作。删除归属能力要在 T05-04 单独验收。

## 五、验收与后续任务

- [x] JSON Schema v1 已提交（语法结构、字段约束与基本关联）。
- [x] Portainer 和 Sub2API 各有契约示例，覆盖单服务、Compose 三服务、生成型 secret、共享依赖、数据目录。
- [x] 逐项核对当前 Deploy 的 Compose、脚本、全局配置模板。
- [x] 明确中心 Git pull 与 Agent 下发边界、端口优先级、服务关联、数据保留和失败不回滚。
- [ ] T03-01：编写**实际 YAML/JSON Schema 校验器**及跨字段检查、CI。
- [ ] T03-02/T03-03：把已验收的 manifest 放入正式应用目录并实施端到端脚本兼容验证。
- [ ] T03-07/08：实现中央应用包封装、传输和 Agent 安全解包。
- [ ] T04-04：共享 env/secrets 原子修改、生成型 secret 与更新保留行为。

**本任务只冻结结构和约束；不会自动改变旧的 Deploy CLI 脚本行为。**
