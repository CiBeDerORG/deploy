# Deploy — Git, CI & Delivery Policy

> 按需读取：提交代码、分支开发、PR、合并、CI、发布、任务交接、交付报告。

Every newly added service's README must include all six sections and the documented automatic credential flow. The final answer must follow the same contract even when the user merely asks "how do I install it?". Where Linux/fnOS and Windows commands differ, label the platform. A branch-only implementation must be identified as such until merged into the default branch. When modifying source, report the branch, commit/PR links, and available CI results; never claim tests or live deployment passed without verification.

## Git 与多 Agent 协作

- 修改前确认当前分支、工作区、目标基线与其他参与者的改动，禁止覆盖或丢弃无关的未提交工作。
- 代码修改采用适合项目的功能分支、原子提交和 PR；合并遵守授权和受保护分支策略，目标为集成到 `main`。不可将已推送误报为已合并。
- 跨会话或跨 Agent 的长任务记录任务目标、验收标准、当前负责人、分支/Commit、完成项、待办、阻塞及 CI 状态；不必复制聊天记录。
- 并发任务优先使用独立分支或 Git Worktree；冲突由明确的集成负责人协调，不得互相覆盖工作结果。

## 非阻塞 CI 与质量门禁

- 开始新工作时检查与本次任务相关的上次 CI 结果；失败且影响当前任务或集成基线时优先修复，无关失败不阻塞独立任务。
- 提交、Push、PR 后无需持续等待 CI；但禁止将 CI pending 视为成功，也不能因不等待而跳过合并所需的质量门禁。支持时使用符合分支保护规则的自动合并。
- 对修改内容执行适用的语法/静态检查、配置校验、生命周期契约测试和回归测试；无法验证的内容必须披露，绝不编造通过结果。
- 严格区分 Implementation Complete、CI Pending、CI Passed、Integrated、Deployment Verified。

## 交付输出契约

- 每次任务结束报告：完成任务、未完成/阻塞事项、修改范围、验证结果与残余风险、分支、Commit、PR、合并状态、构建链接及当前构建状态。
- 新增服务或修改部署说明时，除本规范外必须遵循 `DEPLOYMENT.md` 的六项安装文档/最终回答契约，以及 `SECURITY.md` 的密钥规则。
- 链接和状态仅在实际存在并经过核实时报告；不得将模拟/静态验证描述为真实环境部署成功。
