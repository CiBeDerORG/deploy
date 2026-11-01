# Sub2API → EasyNetTopo / EasyHostAgent M0 集成契约

> 状态：待审静态接口基线；**不是可用的远程安装器**。
> 官方应用描述：[`sub2api/app.yaml`](../sub2api/app.yaml)
> Schema：[`schema/app-manifest-v1.schema.json`](../schema/app-manifest-v1.schema.json)
> 校验器：[`tools/validate_app_manifest.py`](../tools/validate_app_manifest.py)
> EasyNetTopo M0：[跨仓库协议说明](https://github.com/CiBeDerORG/EasyNetTopo/blob/docs/platform-integration-m0/docs/architecture/m0-cross-repo-contracts.md)

## 1. 既有 CLI 行为不变

`sudo bash deploy.sh env` 建立 `<SOFTWARE_ROOT>/deploy/.env`、`.secrets`；`sudo bash deploy.sh sub2api` 使用统一配置调用 install.sh。远程安装不能假设 Agent 已执行过根 `deploy.sh env`，应提供**等价、原子、受权限约束且不会覆盖已有密钥**的配置初始化。

## 2. 固定 Commit 的最小应用资源

从授权 Git 仓库固定提交读取 `sub2api/app.yaml`，再根据 `package.files` 精确提取：

| Git 仓库相对路径 | 目标 SOFTWARE_ROOT 相对路径 | 用途 |
|---|---|---|
| sub2api/deploy/docker-compose.yaml | sub2api/deploy/docker-compose.yaml | 三服务 Compose |
| sub2api/deploy/install.sh | sub2api/deploy/install.sh | 官方受控安装 |
| sub2api/deploy/update.sh | sub2api/deploy/update.sh | 官方受控更新 |
| sub2api/deploy/lib.sh | sub2api/deploy/lib.sh | 安装器本地函数 |
| lib/image-sources.sh | deploy/lib/image-sources.sh | 共享镜像源处理 |

`app.yaml` 和来源 commit/manifest digest 随**包元信息**携带（不是让用户添加到 `package.files`），归档格式和元信息文件名应由跨仓库协议测试固定后实施。

**绝不打包** `<SOFTWARE_ROOT>/deploy/.env`、`.secrets`、`sub2api/data/`、任何 Token 或现存数据。路径穿越、符号链接、特殊文件以及非法落点应在控制端和 Agent 两次校验。

## 3. 安装前置与健康验收

- Agent 必须具有本机授权的 Docker/Compose 执行能力；Linux/AMD64 或 ARM64，或适配的 fnOS 系统。
- `SOFTWARE_ROOT` 以该 Agent 实际配置为准，不能假设它和旧 Deploy 默认值完全相同。
- 端口变量 `SUB2API_HTTP_PORT` 默认 7010；绑定 IP 默认为 `0.0.0.0`。端口和 Compose Project 冲突必须拒绝，不自动停止外部容器。
- 安装前受控地初始化共享 `.env`/`.secrets`，保证 root 权限文件模式 0600，并保护全局配置并发写入。
- `SUB2API_POSTGRES_PASSWORD`、`SUB2API_REDIS_PASSWORD`、`SUB2API_JWT_SECRET`、`SUB2API_TOTP_ENCRYPTION_KEY` 首次留空由既有脚本生成并持久化，更新时不能重置。
- 可选管理员邮箱及密码留空时，Sub2API 上游可在**首次启动日志**输出自动生成的凭据：查看原始容器日志必须受到高权限保护，不能声称所有第三方日志已脱敏。
- `verification.required_services` 是 `sub2api`、`postgres`、`redis`，状态要求 `healthy`；脚本退出码为 0 不等于应用状态已确认。
- PostgreSQL 和 Redis 不映射公网端口，主 Web 入口取实际绑定的端口。
- 更新与默认卸载保留 `sub2api/data/app`、`postgres`、`redis` 三类数据目录；彻底删除需要明确确认及所有权校验。

## 4. 供应链信任边界

本仓库的 Schema/语义验证器只能判定元数据与仓库资源是否一致，**不能审计 Shell 安全性，也不能证明包属于可信发行方**。EasyNetTopo 的 `source_id` 只是控制端内部 UUID，并非信任标记。

在 Agent 实现**主机本地批准的不可变包摘要或验证发布签名**之前，不得仅凭“来自官方 Deploy”“有效 SHA-256”“管理员点击安装”等信号执行安装脚本。第三方 Git 源的 Compose 必须有独立的危险能力限制，不能视作没有 Shell 就自然安全。

## 5. 自动测试与真实环境的区别

`tests/contracts/test_sub2api_easynettopo.py` 只校验当前仓库中的包文件、密钥生成契约、配置依赖、Compose 健康声明和暴露端口，避免今后部署脚本悄悄破坏远程安装所需前置。

本测试不会执行命令、创建容器、核验真实密码管理或证明远程执行安全。真正的 FnOS/Linux 联调需要在 EasyHostAgent 的 bundle/tasks 运行时实现之后另外执行并报告结果。

## 6. 不纳入本轮

- 不批量为其他 Deploy 应用添加 app.yaml。
- 不要求 Deploy 持有控制中心、用户身份或主机连接。
- 不改变现有 install/update 脚本或统一配置格式。
- 不将 EasyTier 组网作为 Sub2API 安装的前置。
