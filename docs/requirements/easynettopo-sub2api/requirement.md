# R001 · Deploy 为 EasyNetTopo V1 提供 Sub2API 应用源（汇总需求）

> 整编时间：2026-11-02。现有 [Sub2API 跨仓契约](../../easynettopo-sub2api-m0.md)、[app.yaml v1 标准](../../easyhostagent-app-manifest-v1.md)、`sub2api/app.yaml`、`schema/app-manifest-v1.schema.json`、`tests/contracts/test_sub2api_easynettopo.py` 是本规格的事实依据。**Deploy 是静态应用资源源，不承担常驻管理或高权限远程执行**。现有 Linux/fnOS/Windows CLI 行为不因集成修改而失效。

## R001 分级需求与状态

| 需求编号与名称 | 父级 | 确认状态 | 交付状态 | 来源与验收 |
| --- | --- | --- | --- | --- |
| R001 · Sub2API V1 应用源（汇总） | — | 已确认 | 进行中 | 等待跨仓真实安装闭环 |
| R001.01 · 合法清单与 Schema/语义校验 | R001 | 已确认 | 待验收 | `sub2api/app.yaml`、Schema 和校验器 |
| R001.02 · 固定版本最小文件包与归属边界 | R001 | 已确认 | 待验收 | `package.files`、共享 lib、拒绝路径穿越 |
| R001.03 · 配置/密钥初始化与更新保留 | R001 | 已确认 | 待验收 | `deploy/.env`、`.secrets`、原子更新要求 |
| R001.04 · Sub2API Compose 健康与卸载保留 | R001 | 已确认 | 待验收 | sub2api、postgres、redis 三服务健康 |
| R001.05 · 不扩大第三方脚本与 Compose 权限 | R001 | 已确认 | 待验收 | 源 ID 非可信证明，危险执行需 Agent 本机授权 |

## 执行边界

- Git 源由 EasyNetTopo 控制端按需获取/刷新，Agent 不直接访问 Git 仓库；代码清单是部署资源描述，不是执行授权。
- 本项目仅需要把 **Sub2API** 作为第一个真实模板；不批量补齐其他应用的 app.yaml。
- 包内不能包含运行时的 `.env`、`.secrets`、数据目录或真实 Token。密钥更新不可重置已有用户值。
- 兼容现有部署脚本，不能因远程接口工作改坏 `deploy.sh`、`deploy.ps1` 或宿主机数据。
- 子需求的“已确认”不等于真实 FnOS 端到端安装验收；汇总交付保持进行中。开发任务归属 [T001 分级任务](tasks.md)。
