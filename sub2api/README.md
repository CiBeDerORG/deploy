# Sub2API

> 应用商店 v2：本应用的字段定义在 `config.yaml`、`secrets.yaml`，图标在 `assets/icon.svg`；实际配置位于 `<SOFTWARE_ROOT>/sub2api/config/.env`、`config/.secrets`。先运行 `sudo bash deploy.sh env` 和 `sudo bash deploy.sh sub2api sync` 初始化，再编辑实际文件。旧全局值仅在新文件缺少对应项时迁入，更新不覆盖已有值。全局镜像源等公共设置仍在 `deploy/.env`。参见[通用契约与操作说明](../docs/app-store-contract.md)。


使用 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) 官方镜像，部署应用 + PostgreSQL 18 + Redis 8。数据库与 Redis **不发布宿主机端口**；所有数据保存于 `<SOFTWARE_ROOT>/sub2api/data/`。

## 配置和安装

先在 deploy 仓库根目录执行 `sudo bash deploy.sh env`，然后运行 `sudo bash deploy.sh sub2api sync` 并检查应用配置：
- `.env`：`SUB2API_HTTP_PORT=7010`、`SUB2API_BIND_IP=0.0.0.0`。
- `.secrets`：`SUB2API_POSTGRES_PASSWORD`、`SUB2API_REDIS_PASSWORD`、`SUB2API_JWT_SECRET`、`SUB2API_TOTP_ENCRYPTION_KEY` **均允许空值**（如 `KEY=`、`KEY=""`、`KEY=''` 或缺少该项），首次安装时分别生成并持久化，随后才校验 Compose 所需的最终运行值；不会限制或改写已填写的非空自定义密钥。`SUB2API_ADMIN_EMAIL` / `SUB2API_ADMIN_PASSWORD` 可分别填写或留空，未填的一项由官方首启独立随机生成，凭据仅在首次启动日志中打印。自定义管理员密码只遵循官方首次初始化要求的 8–72 UTF-8 字节；管理员邮箱格式由官方校验。`SUB2API_UPDATE_PROXY_URL` 可选，只用于在线更新和定价数据获取，**不是全部 API 出站代理**。

```bash
sudo bash deploy.sh sub2api
sudo docker logs sub2api   # 两项管理员凭据留空时，查看首次启动日志
sudo bash deploy.sh sub2api update
```

入口：`http://<服务器IP>:7010`。对公网部署请使用 HTTPS 反向代理、限制管理后台来源。改变 PostgreSQL 密码不能只改 `.secrets`：现有数据里的数据库用户密码不会随容器重建自动改变。更新不会删除数据，也不会自动升级为其他 PostgreSQL 大版本；升级前请对 `data/` 做一致性备份，严禁在数据库运行时直接复制当成完整热备。镜像目前跟随官方 `latest`，有严格变更要求请自行固定版本标签。

检查：`docker compose -f <SOFTWARE_ROOT>/sub2api/deploy/docker-compose.yaml ps`。如失败：`docker logs --tail=100 sub2api`、`docker logs --tail=100 sub2api-postgres`、`docker logs --tail=100 sub2api-redis`。
