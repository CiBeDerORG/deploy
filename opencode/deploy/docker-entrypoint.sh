#!/bin/sh
set -eu

# 让 bind mount 中由容器新建的文件默认保持组可写。
# 配合宿主机目录的 setgid，可让文件继承宿主机维护组。
umask 0002

# V2 standalone server 使用自己的服务密码。
# 启动前把 .env 中的密码同步进去，保证重建容器后密码保持一致。
if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    opencode service set password "${OPENCODE_SERVER_PASSWORD}" >/dev/null
fi

exec opencode "$@"
