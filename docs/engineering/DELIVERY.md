# Deploy — Git, CI & Delivery Policy

> 按需读取：代码执行工具、辅助脚本、仓库卫生、提交代码、分支开发、PR、合并、CI、发布、交付报告。

Every newly added service's README must include all six sections and the documented automatic credential flow. The final answer must follow the same contract even when the user merely asks "how do I install it?". Where Linux/fnOS and Windows commands differ, label the platform. A branch-only implementation must be identified as such until merged into the default branch. When modifying source, report the branch, commit/PR links, and available CI results; never claim tests or live deployment passed without verification.

## Git 与变更隔离

- 修改前确认当前分支、工作区、目标基线与其他参与者的改动，禁止覆盖或丢弃无关的未提交工作。
- 代码修改采用适合项目的功能分支、原子提交和 PR；合并遵守授权和受保护分支策略，目标为集成到 `main`。不可将已推送误报为已合并。

## 执行工具与仓库卫生（Execution Tooling & Repository Hygiene）

- 优先使用现有文件编辑、Shell、Git、API 和 CI 工具直接完成一次性任务；不得仅为驱动当前 Agent 任务而在仓库新增辅助执行脚本、任务调度脚本、进度/状态文件或多余的流程包装层。
- 复杂的一次性批量操作确有必要使用脚本时，优先在系统临时目录运行，或直接使用一次性命令；若临时文件必须出现在工作区，应在任务结束时清理，并检查变更集，避免误提交临时产物、日志、凭据或本地环境文件。
- 正式产品功能、部署生命周期脚本（安装、更新、卸载等）、可复用的自动化测试/CI 工具，以及用户明确要求交付的脚本可以新增并纳入版本管理，但必须具备明确用途并遵守现有工程规范。
- 不得借仓库精简之名跳过必要测试、验证、诊断或部署契约；判断依据是文件是否具有持续工程价值，而不是脚本数量。

## 非阻塞 CI 与质量门禁

- 开始新工作时检查与本次任务相关的上次 CI 结果；失败且影响当前任务或集成基线时优先修复，无关失败不阻塞独立任务。
- 提交、Push、PR 后无需持续等待 CI；但禁止将 CI pending 视为成功，也不能因不等待而跳过合并所需的质量门禁。支持时使用符合分支保护规则的自动合并。
- 对修改内容执行适用的语法/静态检查、配置校验、生命周期契约测试和回归测试；无法验证的内容必须披露，绝不编造通过结果。
- 严格区分 Implementation Complete、CI Pending、CI Passed、Integrated、Deployment Verified。

## 交付输出契约

- 每次任务结束报告：完成任务、未完成/阻塞事项、修改范围、验证结果与残余风险、分支、Commit、PR、合并状态、构建链接及当前构建状态。
- 新增服务或修改部署说明时，除本规范外必须遵循 `DEPLOYMENT.md` 的六项安装文档/最终回答契约，以及 `SECURITY.md` 的密钥规则。
- 链接和状态仅在实际存在并经过核实时报告；不得将模拟/静态验证描述为真实环境部署成功。
