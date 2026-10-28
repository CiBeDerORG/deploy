# T03-03 — Sub2API 正式应用清单

> 2026-10-28，Deploy/main；**代码/静态契约已提交，Deploy GitHub Actions runner 未正常执行，CI 待验收**。

## 交付

- [正式清单](../sub2api/app.yaml) 位置严格为 `sub2api/app.yaml`，`id: sub2api`、`compose_project: sub2api` 对应现有 Compose 文件中的 `name: sub2api`。
- 采用现有三服务 Compose：`sub2api`（8080/tcp）、`postgres`、`redis`；验收要求全部 healthy 且限时 240 秒。多个容器在 EasyTier Docker 列表中按 Compose 项目分组而非独立应用。
- Web 对外端口由 `SUB2API_HTTP_PORT` 设置（默认 7010），绑定 IP 为 `SUB2API_BIND_IP`（默认 0.0.0.0），对应 Compose 中的显式变量模板；数据库与 Redis 端口不声明为公共 Web 入口。
- `SUB2API_POSTGRES_PASSWORD`、`SUB2API_REDIS_PASSWORD`、`SUB2API_JWT_SECRET`、`SUB2API_TOTP_ENCRYPTION_KEY` 声明由安装脚本生成并保存到共享 `.secrets`。可选初始管理员邮件、密码及代理 URL 同样放在 .secrets；禁止把真实凭证加入部署包。
- 包含 `sub2api/deploy/docker-compose.yaml`、`install.sh`、`update.sh`、`lib.sh` 与通用 `lib/image-sources.sh`，公共库目标路径 `deploy/lib/image-sources.sh`。不交付现有用户数据。
- 保留 `sub2api/data/app`、`sub2api/data/postgres`、`sub2api/data/redis` 目录，uninstall 仅为非孤儿清理 Compose down，默认保留数据；旧 CLI 和安装逻辑保持原样。
- 已纳入校验器和负面回归：项目/服务/端口不存在、子脚本漏打包、健康检查不符、敏感字段不当默认、数据目录映射不匹配均应阻止发布。

## 代码验收

- [x] 与先前 v1 示例一致的正式清单已提交；项目与宿主 Compose 文件吻合。
- [x] 多服务、Web 主入口、密钥字段、共享库、数据目录与现有源码做静态核验。
- [x] 校验器 `--all` 与 Python 正反例自动化测试已接入 CI。
- [ ] Deploy GitHub Actions 真正执行测试（目前任务启动前失败、无步骤输出）。
- [ ] FnOS 多容器安装、更新、保留数据与真实访问验证（属于 M4/M5 现场任务）。

本项不额外创建容器，也不把三服务变成三套受管应用。既有部署行为不修改；正式受管实例所有权与任务执行在 M4 实现。
