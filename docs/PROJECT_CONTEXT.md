# Deploy · Agent 项目上下文入口

这是 Claudian、Codex、OpenCode 共用的**读取协议**，不是第二份知识库。不依赖历史聊天，不自动加载所有知识。

## 何时读什么

| 任务 | 最小读取 |
| --- | --- |
| Git 状态/差异、构建、格式、范围明确的小修 | 本仓库 AGENTS.md → 相关规范/目标文件；跳过外部知识 |
| 项目定位、历史原因、产品取舍、决策是否有效 | 本页 → 既有 INDEX.md 的相关节 → MEMORY.md 的相关决策 |
| 摘要不足或存在争议 | 只跟随相关来源链接；规范回仓库，背景笔记逐篇读，不递归扫 Vault |
| 当前分支/提交/工作区、CI/PR/部署结果 | 实时 Git/CI/现场证据；不从笔记或聊天恢复为当前事实 |

## 定位已有知识（GitHub 统一入口）

共享知识仓库：[CiBeDerORG/DevKnowledge](https://github.com/CiBeDerORG/DevKnowledge)；Git 远程为 `https://github.com/CiBeDerORG/DevKnowledge.git`。
默认读取 `main` 的相关章节，需要复现历史时改用已核实的 Commit SHA。

- [Deploy INDEX.md](https://github.com/CiBeDerORG/DevKnowledge/blob/main/02-%E9%A1%B9%E7%9B%AE/Deploy/INDEX.md)：导航、背景与证据边界。
- [Deploy MEMORY.md](https://github.com/CiBeDerORG/DevKnowledge/blob/main/02-%E9%A1%B9%E7%9B%AE/Deploy/MEMORY.md)：长期稳定决策和来源，不是任务日志。
- [研发知识工作台](https://github.com/CiBeDerORG/DevKnowledge/blob/main/00-%E5%B7%A5%E4%BD%9C%E5%8F%B0/Home.md)：其他项目入口；本任务不因此扫描其他项目知识。

这是 2026-11-01 用户指定的统一入口，替代旧的本机 Vault 绝对路径、`OBSIDIAN_VAULT_ROOT` / `.context.local.json` 定位协议；不创建知识副本或同步服务。
本机 Claudian Project 可继续绑定同一份工作副本的 `02-项目/Deploy/MEMORY.md`，绑定路径不需要改成 URL。

仅需纯 Markdown 时，将文件 URL 的 `github.com/CiBeDerORG/DevKnowledge/blob/main/` 替换为 `raw.githubusercontent.com/CiBeDerORG/DevKnowledge/main/`；访问仍须遵循网络和仓库认证权限。
笔记中的 `file://` / 旧本地源码路径只作当时的来源线索；技术来源重新定位到**当前 checkout 的相同相对路径**，不跨机器照抄盘符，也不误指向知识仓库。
只跟随当前问题需要的来源，不递归读取整个知识库。

## 三种事实不能混用

- **长期知识**：INDEX / MEMORY 中带来源的项目背景、已确认/待讨论/superseded 决策；只在稳定事实变化且有授权时维护。
- **开发规范与实现**：当前 checkout 的 AGENTS.md、`docs/engineering/`、技术文档和源码；摘要不能取代原文。计划文档不是批准或交付证明，分支方案不能自动推广到 main。
- **Git 实时状态**：需要时执行 `git status --short --branch`、`git rev-parse HEAD`、`git diff --name-only`、`git diff --cached --name-only`。Codex/Claudian 的 shell 工作目录可能被本机 PowerShell profile 改变，使用显式 `git -C <当前仓库绝对根目录> ...` 核对，读文件同样使用绝对路径；OpenCode 的只读 agent 使用其已授权的确切命令及正确工作目录。不得因已有笔记写了分支/Commit 就省略现场检查；本地 origin/upstream 不证明远端最新。CI 未查询就写未核实，不自行执行 push。

## 读取权限与本机兼容

AGENTS 只负责发现入口，不授予 GitHub 网络或仓库权限。

- 使用当前会话已有的授权联网读取能力访问上述 URL；仓库需要认证时使用现有安全认证渠道，不在提示词、笔记或 URL 中放 Token / Cookie。
- Git 能推送知识仓库，不代表 Codex、OpenCode、容器或网页读取工具已获得同样的认证；分别核实实际可读性。
- 旧本机 `deploy-context` 权限 profile / 只读 agent 若禁网，不能直接完成 GitHub 读取。遇限制应报告，不切全访问、不自动放行网络、不改全盘 ACL，也不虚构读取成功。
- **Claudian**：保留现有 Deploy Project 与 MEMORY 的 Vault 相对路径绑定；本机自动注入的记忆与 GitHub 进一步读取须区分，不声称「从未加载记忆」，不需要旧会话。
- 用户明确要求使用本地工作副本时，才按其提供且已获授权的路径读取；不默认恢复旧机器映射。当前源码、规则和 Git 状态始终在当前 Deploy checkout 核对。

本轮只更新知识路由，不修改被忽略的 `.context.local.json`、`.codex/config.toml`、`.opencode/opencode.jsonc`，不改变原有开发启动策略或权限。
Windows 沙箱、WSL 和容器的网络 / 认证分别验收；不自动新增挂载或同步服务。

## 失败处理与恢复验收

URL 内容缺失、GitHub 网络 / 认证拒绝或运行时启动失败：列出实际尝试的 URL / 错误，停止历史结论推断；仅在无需背景的任务可继续时说明降级范围。不猜测正文、不搜索整盘、不自动放宽权限。

新建**不恢复/不 fork 历史**的独立会话，仅给任务（不给知识正文或答案）：要求自行发现入口，恢复三条带来源及有效范围的历史决策，现场核对 Git，并列实际读取 URL、版本与未核实项。
另用新会话仅问 Git 状态，验证没有读取 INDEX/MEMORY。验收快照记录于知识库的 [Deploy 协作验证](https://github.com/CiBeDerORG/DevKnowledge/blob/main/02-%E9%A1%B9%E7%9B%AE/Deploy/%E5%8D%8F%E4%BD%9C%E9%AA%8C%E8%AF%81.md)，不写回长期 MEMORY。本轮未执行这些独立模型验收。
