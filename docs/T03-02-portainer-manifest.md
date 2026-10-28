# T03-02 — Portainer 正式应用清单

> 2026-10-28，Deploy/main；**代码/静态契约已提交，Deploy GitHub Actions runner 未正常执行，CI 待验收**。

## 交付

- [正式清单](../portainer/app.yaml) 位置严格为 `portainer/app.yaml`，`id: portainer`、`runtime.compose_project: portainer` 与现有 `portainer/deploy/docker-compose.yaml` 的 `name: portainer` 一致。
- Docker Compose v2, Linux/FnOS, amd64/arm64；声明独立 Web 入口 `PORTAINER_HTTP_PORT -> portainer:9000/tcp`；`PORTAINER_ADMIN_PASSWORD` 仅从共享 `.secrets` 加载，不在打包文件中包含凭证。
- 仅交付 `portainer/deploy/docker-compose.yaml`、`install.sh`、`update.sh` 以及公共 `lib/image-sources.sh`（目标 `deploy/lib/image-sources.sh`），不下发用户数据/共享真实 `.env` / `.secrets`。
- install/update 复用现有脚本，uninstall 使用明确的 Compose down 且 `remove_orphans: false`；仅声明 `portainer/data` 数据目录，卸载默认保留数据。
- 修复已有 `portainer/deploy/install.sh` 的危险逻辑：先前同名容器在 install 时会被直接 `docker stop` + `docker rm`，即使它不是 Portainer 项目。现在先查询 Compose project label，非 `portainer` 则拒绝操作；本项目容器交由 Compose 管理，不再预先手工 rm，失败保留现场。
- 新增回归断言：正式清单对应示例、打包文件完整、项目与参数匹配，以及 Portainer 脚本不能重新引入直接删除同名非自有容器的代码。

## 代码验收

- [x] 正式文件与契约示例保持同内容（只有第一行说明不同）。
- [x] 项目名、主要端口、package.paths、公共脚本依赖由读取仓库文件的检查核实。
- [x] 校验器 `python3 tools/validate_app_manifest.py --all` 与 Python 回归套件已接入 GitHub Actions。
- [ ] Deploy GitHub Actions 真正执行测试（当前仓库 Actions job 无执行步骤失败）。
- [ ] FnOS 实机通过可信安装任务部署 Portainer（属于 T04-08；M4 还未实现）。

本任务的**正式元数据交付完成，但 CI 验收尚未过门槛**。不应把 YAML 校验当作 Shell 脚本无风险证明，也不应在未建立受管所有权时调用这些动作。
