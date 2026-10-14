# Sub2API

使用 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) 官方镜像，部署应用 + PostgreSQL 18 + Redis 8。数据库与 Redis **不发布宿主机端口**；所有数据保存于 `<SOFTWARE_ROOT>/sub2api/data/`。

## 配置和安装

先在 deploy 仓库根目录执行 `sudo bash deploy.sh env`，然后检查统一配置：
- `.env`：`SUB2API_HTTP_PORT=7010`、`SUB2API_BIND_IP=0.0.0.0`。
- `.secrets`：四项数据库 / Redis / JWT / TOTP 密钥留空时首次安装生成并持久化；`SUB2API_ADMIN_EMAIL` 和 `SUB2API_ADMIN_PASSWORD` 可同时设置（按官方首次初始化要求，密码 8-72 字节；非部署器自定义限制），也可同时留空，官方首启会随机生成管理员账号与密码，凭据仅在首次启动日志中打印。可选 `SUB2API_UPDATE_PROXY_URL` 只影响官方在线更新，**不是全部 API 出站代理**。

```bash
sudo bash deploy.sh sub2api
sudo docker logs sub2api   # 两项管理员凭据留空时，查看首次启动日志
sudo bash deploy.sh sub2api update
```

入口：`http://<服务器IP>:7010`。对公网部署请使用 HTTPS 反向代理、限制管理后台来源。改变 PostgreSQL 密码不能只改 `.secrets`：现有数据里的数据库用户密码不会随容器重建自动改变。更新不会删除数据，也不会自动升级为其他 PostgreSQL 大版本；升级前请对 `data/` 做一致性备份，严禁在数据库运行时直接复制当成完整热备。镜像目前跟随官方 `latest`，有严格变更要求请自行固定版本标签。

检查：`docker compose -f <SOFTWARE_ROOT>/sub2api/deploy/docker-compose.yaml ps`。如失败：`docker logs --tail=100 sub2api`、`docker logs --tail=100 sub2api-postgres`、`docker logs --tail=100 sub2api-redis`。
