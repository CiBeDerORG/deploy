# Deploy — App Store Contract

## 目录即应用

每个标准 Docker 应用由 `<app-id>/app.yaml` 声明，安装配置、Compose 和受控生命周期脚本位于该应用的 `deploy/` 下。EasyNetTopo 从指定 Git 应用源的固定 Commit 扫描、验证并展示目录，**新增应用无需在 EasyNetTopo 或 EasyHostAgent 中注册应用名**。新增服务必须满足 `schema/app-manifest-v1.schema.json`、`tools/validate_app_manifest.py`、脚本安全检查和统一 `.env`/`.secrets` 模板契约。

## 主机执行

仅已配对的 EasyNetTopo 控制端可以通过 EasyHostAgent 操作可信来源中的包；不再启用 `EASYHOSTAGENT_APP_GRANTS` 逐应用授权。标准 Deploy 应用使用 `<SOFTWARE_ROOT>/<app-id>/deploy/`，更新执行固定版本安装包中声明的 `update.sh`，卸载执行 `uninstall.sh`，默认保留数据。

已有 Deploy Compose 项目须先验证项目名、全部容器的工作目录与 Compose 文件位置完全匹配，才自动关联为受管应用。同名但目录不同的容器不得接管；旧版私有安装路径继续兼容。EasyHostAgent 自身由原生 systemd 管理，首次安装与卸载仍需使用主机终端的 deploy.sh 命令。

