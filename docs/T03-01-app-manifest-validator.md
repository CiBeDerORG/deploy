# T03-01 — Deploy `app.yaml` v1 解析与安全校验器

> 2026-10-28，仓库 `CiBeDerORG/deploy`，分支 `main`。
> 状态：**实现、回归用例与 CI 工作流代码已提交；Deploy GitHub Actions 无执行步骤即失败，尚不能标记 T03-01 整体 DONE。**

## 使用方式

本地可执行：

```bash
python3 -m pip install "PyYAML>=6,<7" "jsonschema>=4.20,<5"
python3 tools/validate_app_manifest.py --examples
python3 tools/validate_app_manifest.py --all
python3 tools/validate_app_manifest.py portainer/app.yaml
python3 -m unittest discover -s tests/contracts -p 'test_*.py' -v
```

`--examples` 校验两份已有**契约样例**，不是发布正式商店商品；`--all` 校验仓库根目录中的 `<id>/app.yaml`。T03-02/T03-03 已提交正式 `portainer/app.yaml` 和 `sub2api/app.yaml`；只有校验及 CI 验收通过后才应进入可信中央商品列表。命令退出码 0=当前输入均通过，1=至少一份校验失败。返回 JSON 行只含结构化清单摘要和相对错误位置，不输出用户密钥实际内容。

## 已实现的校验

1. **JSON Schema v1**：类型、必填、额外字段、类别、URL 格式、安全路径与禁止明文 `secret.default`；未知版本立即拒绝。
2. **YAML 解析**：safe loader，不接受重复 mapping key，不解析任意 Python 对象；文件及字段错误 fail closed。
3. **清单位置**：正式发布清单只能是 `<id>/app.yaml`，路径必须与 `id` 匹配；Fixtures 只允许 `schema/examples/<id>.app.yaml`。
4. **部署包白名单**：源文件存在且是普通文件；父级到文件自身均禁止软链接；路径不得绝对/反斜杠/穿越/隐藏凭证或进入 data/state/backup/workspace/runtime 等受保护目录。源与目标不允许大小写折叠后冲突；应用文件只可落在自身目录，公共库只可从 `lib/**` 映射到 `deploy/lib/**`；单文件最多 5 MiB、全包最多 24 MiB。
5. **Compose 关联**：项目 `name:` 必须等于 `runtime.compose_project`；服务必须存在、健康验收服务必须有 healthcheck；端口映射必须逐项匹配 `host_port_key`、可选 `bind_address_key`、`container_port`、协议与声明的 Compose service；不能通过容器端口数字字符串“碰巧包含”冒充验证通过。识别 `${VAR:?message}` 中的冒号。
6. **配置值**：按键唯一；敏感字段只能放 secrets、缺失/空默认值；端口、IPv4、number、boolean 默认值及范围类型校验。脚本生成型 secret 必须可在安装脚本里找到对应实现；全局 `.env.example` / `.secrets.example` 必须声明字段。
7. **动作白名单**：V1 仅 install/update 的已打包可执行 shell 脚本，以及 uninstall 的 `compose_down`；禁用参数注入、任意卸载脚本、remove_orphans；`source "$DEPLOY_DIR/lib.sh"` 与公共 image-sources.sh 必须随包交付。
8. **数据归属**：列明的数据路径必须是应用自己的 data 子目录且对应实际 Compose 相对路径挂载；声明的命名卷必须在 Compose 定义；卸载默认保留数据，不因 manifest 暗示可以任意清理磁盘。
9. **主入口顺序**：选取第一个 Web purpose 端口，若无则选声明的第一个其他端口；无端口则不推断入口。

**实际安全限制**：校验脚本从不执行用户脚本或 Docker；它验证的是结构、文件映射和可验证的一致性，**不是对任意 Shell 脚本恶意行为的形式化证明**。M3 T03-07 固定 Git commit + SHA-256 构建不可变包，M4 Agent 才能结合权限/归属对可信包执行，不准将“校验通过”直接当作执行授权。

## 发现并修复的真实问题

原 Portainer 示例遗漏了 `lib/image-sources.sh`，但其 `install.sh` 使用 `$SOFTWARE_ROOT/deploy/lib/image-sources.sh`；本轮补足 `schema/examples/portainer.app.yaml` 的 `package.files` 映射。这是 T03-02 发布正式 app.yaml 时必须保留的依赖，否则新 Agent 主机没有完整 Deploy checkout 时安装会失败。

## CI 运行结果与阻塞

工作流：`.github/workflows/app-manifest-contracts.yml`，新增 `tools/validate_app_manifest.py`、Portainer/Sub2API 脚本、共享模板等触发路径；安装 PyYAML 与 jsonschema，运行 Python `compileall`、既有契约测试、T03-01 负例测试及 CLI `--examples --all`。

- 之前 T00-05 构建 [#40386319978](https://github.com/CiBeDerORG/deploy/actions/runs/40386319978)：失败，工作未执行步骤。
- 本轮 [#40672562001](https://github.com/CiBeDerORG/deploy/actions/runs/40672562001)：失败，job `manifests` 未列出任何执行步骤、几秒内结束。没有单元测试输出；此结果**不能判断校验器有无逻辑错误**。
- 目前没有可证实的具体失败根因；需要由仓库维护者检查该私有 Deploy 仓库的 GitHub Actions 启用、组织策略及运行额度/账单或 runner 启动失败事件。不要在无日志情况下把原因断言成 Python 代码错误。
- 下次工作开始按全局规则先核对最新 run。若允许使用 CI，就针对真实测试日志修复再验收；**不要把 CI 失败写成成功**。

## 后续任务

- T03-02/T03-03 已将实际 `app.yaml` 纳入 Portainer/Sub2API 项目目录，并补强 Portainer 的非自有容器防误删逻辑；下轮对其执行可信商店完整验证，旧 deploy CLI 仍保留。
- T03-07 应严格打包本工具验证过的 source 文件，并绑定固定 commit 与完整 SHA-256；最终执行端还需要再校验。
- 本项 CI/真实发布前验证完成之前状态继续 `IN_PROGRESS`，而不是 `DONE`。
