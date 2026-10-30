# Deploy — AI Agent Engineering Rules

> 此文件是项目级 AI Agent 常驻规则和按需加载入口。具体规范按任务读取；不要在每次会话无条件加载所有文档。详细规则为强制约束，迁移至专项规范不表示降级或废止。

## 核心约束（Always-On）

1. **Architecture First**：修改前核对仓库现状、依赖和现有实现；优先复用公共能力，禁止未经授权的架构重构。
2. **Minimal Change**：采用最小变更集，保持向后兼容；不得覆盖其他开发者/Agent 的工作。
3. **Lifecycle Contract**：新增服务须符合统一入口、安装/更新/卸载契约、配置与数据持久化策略；只声明已实现的命令。
4. **Secure by Default**：保留用户现有凭据原值，不擅自增加密码限制；可安全生成的可选密钥首次留空时生成并持久化，后续更新不覆盖；默认卸载保留数据。
5. **Idempotency**：安装与更新须支持安全重试，避免重复实例、配置覆盖及意外数据删除。
6. **Evidence-Based Verification**：不臆测上游能力，不虚构命令或测试结论；根据风险执行适用检查，保留事实证据。
7. **Git & CI**：开发前检查分支及相关既有 CI；失败优先按关联性修复。提交、Push、PR、合并依授权与质量门禁执行；无需持续等待 CI，不得绕过保护规则。
8. **Delivery Contract**：每次任务交付报告完成项、待办/风险、分支、Commit、PR、合并状态、构建链接及真实验证状态。

## 按需加载（Task-Based Routing）

仅阅读与当前任务相关的规范；跨领域任务可加载多个文件：

- 架构、公共能力、跨平台或重构 → [ARCHITECTURE.md](docs/engineering/ARCHITECTURE.md)
- 新增服务、安装/更新/卸载、Docker、持久化或**用户询问安装方式** → [DEPLOYMENT.md](docs/engineering/DEPLOYMENT.md)
- 密码、Token、认证、配置解析、权限、密钥生成/保留 → [SECURITY.md](docs/engineering/SECURITY.md)
- 代码修改的提交/PR/CI 和交付报告 → [DELIVERY.md](docs/engineering/DELIVERY.md)

新增服务和安装文档变更通常同时涉及 Deployment、Security 与 Delivery，必须读取对应专项规范。历史强制条款已按原文迁移到专项规范，不能因根规则精简而忽略。

## 执行原则

- **先理解、再修改、后验证**；小任务避免过度分析。
- 普通常规任务在授权范围内自主推进；生产数据删除、权限扩大及其他高风险操作须明确授权。
- 优先用脚本/CI 落实确定性质量门禁，不把提示词当作唯一验证手段。
- 以真实完成状态报告交付，不把「已触发构建」写成「构建成功」，不把「已提交」写成「已合并」。
