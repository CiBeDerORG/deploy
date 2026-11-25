# Maestro CLI（macOS 原生安装）

Maestro 可以通过 ADB 操作 Android 真机，把操作步骤写成 YAML 流程并在同一台或另一台设备上重复执行。在 macOS 上使用 deploy 的统一入口管理该工具。

## 1. 配置文件

Maestro 使用当前用户的 Homebrew 安装。部署参数无需填写，也无需运行 `bash deploy.sh env` 或编辑 `deploy/.env`、`deploy/.secrets`。YAML 流程由用户保存到自己的项目，例如 `.maestro/smoke.yaml`。以下设置让当前终端会话使用 Homebrew 的 Java。

```bash
export JAVA_HOME="$(brew --prefix openjdk)/libexec/openjdk.jdk/Contents/Home"
```

## 2. 运行要求

使用 Homebrew 支持的 Apple Silicon 或 Intel Mac，以普通登录用户运行，确保 `brew` 在 `PATH` 中，且能访问 Homebrew 及 Maestro 的 GitHub 发布源。该原生入口无需 `sudo` 或 Docker Desktop。Maestro 官方配方依赖 OpenJDK 17 或更高版本，Homebrew 安装时处理该依赖。脚本优先使用现有可执行的 `adb`，缺少时通过 Homebrew 安装 `android-platform-tools`。[Maestro 官方配方](https://github.com/mobile-dev-inc/homebrew-tap/blob/HEAD/Formula/maestro.rb)

安装会指定完整配方名 `mobile-dev-inc/tap/maestro`。按 Homebrew 6 及后续版本的规则，安装者信任的是 Maestro 这一项配方，无需预先信任整个第三方 tap。[Homebrew 的 tap 信任规则](https://docs.brew.sh/Tap-Trust)

连接 Android 真机时，先在手机的开发者选项中启用 USB 调试，连接 Mac，在手机上确认本机调试授权。准备回放的目标应用应已安装。[Android 真机说明](https://docs.maestro.dev/get-started/supported-platform/android)

## 3. 账号与凭据

安装 CLI 和本地运行普通 YAML 流程无需 Maestro Cloud 账号、密码或 API Key。ADB 自行管理本机设备授权密钥。选择 Maestro Cloud 或云端 AI 功能时，按上游指引通过自己的账号授权。[Maestro AI 服务说明](https://docs.maestro.dev/maestro-flows/workspace-management/ai-test-analysis)

## 4. 安装、检查与可选 Codex 接入

Deploy 的 EasyHostAgent 安装脚本目前支持 Apple Silicon（arm64）Mac。通过 EasyNetTopo 安装时，先将控制台和目标 Mac 的 EasyHostAgent 更新到支持 `macos_homebrew` 的版本，并在控制台刷新 Deploy 应用源。为已配对的 Mac 选择 Maestro 并点击「安装」。Agent 以登录用户身份使用本机 Homebrew 安装配方、补齐 ADB 并验证 CLI 能启动。目标 Mac 可以在没有本地 Deploy 代码检出的情况下接受安装任务。

也可以在包含该功能的 deploy 仓库根目录运行以下命令。第一条应列出 `maestro`。

```bash
bash deploy.sh list
bash deploy.sh maestro install
export JAVA_HOME="$(brew --prefix openjdk)/libexec/openjdk.jdk/Contents/Home"
"$(brew --prefix)/bin/maestro" --version
adb devices -l
```

版本号验证 CLI 能启动。连接真机后，`adb devices -l` 中的设备状态应为 `device`。准备好 YAML 文件后，在文件所在项目中运行本地流程。

```bash
"$(brew --prefix)/bin/maestro" test .maestro/smoke.yaml
```

如需让 Codex 探索手机界面并生成流程，可以单独注册官方 MCP。下例给 Codex 明确指定 Java 和 Maestro 的绝对路径，适用于桌面端与交互式终端环境变量有差异的场景。通过标准输入输出（stdio）通信，无需配置服务端口。[Maestro 的 Codex 接入说明](https://github.com/mobile-dev-inc/maestro-docs/blob/main/introduction/get-started/maestro-mcp.md#L79-L119)

```bash
codex mcp add maestro --env "JAVA_HOME=$(brew --prefix openjdk)/libexec/openjdk.jdk/Contents/Home" -- "$(brew --prefix)/bin/maestro" mcp
codex mcp get maestro
```

## 5. 卸载

```bash
bash deploy.sh maestro uninstall
```

卸载仅移除官方 Maestro 配方，保留 ADB、OpenJDK、设备授权、用户流程和 Maestro 用户配置。若曾手动接入 Codex，可另行用 `codex mcp remove maestro` 移除该注册项。

## 6. 更新

```bash
bash deploy.sh maestro update
```

更新指定 Maestro 官方配方，保留流程与用户配置。尚未安装时会完成首次安装；已安装时会检查 ADB 和 Java，并验证更新后的 CLI 可启动。
