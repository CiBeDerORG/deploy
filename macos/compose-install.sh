#!/usr/bin/env bash
# 仅用于 macOS Docker Desktop 的已适配 Compose 应用。
# 不尝试在 macOS 启动 systemd，也不通过 sudo 运行 Docker。
set -euo pipefail
set +x
umask 077
die() { printf 'macOS Compose：%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(id -u)" -ne 0 ]] || die "仅限 macOS 普通用户"

TASK="${1:-}"; ACTION="${2:-}"; SOFTWARE_ROOT="${3:-}"
case "$TASK" in easynettopo|portainer) ;; *) die "未经适配的应用：$TASK" ;; esac
case "$ACTION" in install|update|uninstall) ;; *) die "不支持操作：$ACTION" ;; esac
[[ "$SOFTWARE_ROOT" == /* && -d "$SOFTWARE_ROOT" && ! -L "$SOFTWARE_ROOT" ]] || die "无效软件根目录"
BASE_DIR="$SOFTWARE_ROOT/$TASK"
DEPLOY_DIR="$BASE_DIR/deploy"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
[[ -f "$ENV_FILE" && -f "$SECRETS_FILE" && ! -L "$ENV_FILE" && ! -L "$SECRETS_FILE" ]] ||
    die "统一配置缺失或不安全；请先运行 bash deploy.sh env"
[[ -f "$DEPLOY_DIR/docker-compose.yaml" && ! -L "$DEPLOY_DIR/docker-compose.yaml" ]] ||
    die "应用 Compose 文件缺失或不安全"
[[ "$(stat -f '%Lp' "$SECRETS_FILE")" == 600 ]] || die ".secrets 必须设为 0600"
source "$SOFTWARE_ROOT/deploy/lib/versions.sh"
deploy_load_versions "$SOFTWARE_ROOT" || exit 1

# 仅按字面读取配置，决不 source .env 或 .secrets；配置值不会作为 shell 代码执行。
read_value() {
    local file="$1" wanted="$2" line key value
    [[ -f "$file" && ! -L "$file" ]] || { printf ''; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || die "无效配置行：$file"
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "无效配置键：$file"
        if [[ "$key" == "$wanted" ]]; then
            value="${line#*=}"
            case "$value" in
                \"*\") value="${value:1:${#value}-2}" ;;
                \'*\') value="${value:1:${#value}-2}" ;;
            esac
            printf '%s' "$value"
            return 0
        fi
    done < "$file"
    printf ''
}

read_global() { read_value "$ENV_FILE" "$1"; }
read_secret() { read_value "$SECRETS_FILE" "$1"; }
validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( 10#$value > 0 && 10#$value <= 65535 )) ||
        die "无效端口：$value"
}
# GHCR 路由与 Linux/fnOS 共用 lib/image-sources.sh；卸载不读取镜像配置、不推进轮换记录。

compose() {
    if [[ "$TASK" == easynettopo ]]; then
        docker compose --env-file /dev/null --project-name easynettopo --project-directory "$DEPLOY_DIR" \
            -f "$DEPLOY_DIR/docker-compose.yaml" -f "$DEPLOY_DIR/docker-compose.macos.yaml" "$@"
    else
        docker compose --env-file /dev/null --project-name portainer --project-directory "$DEPLOY_DIR" \
            -f "$DEPLOY_DIR/docker-compose.yaml" "$@"
    fi
}

# 避免根据容器名称误接管别人的 Compose 项目。
verify_ownership() {
    local name project service working allowed
    if [[ "$TASK" == easynettopo ]]; then
        allowed="$(docker ps -a --filter label=com.docker.compose.project=easynettopo --format '{{.Names}}')" ||
            die "无法读取 EasyNetTopo Compose 项目"
        while IFS= read -r name; do
            case "$name" in ''|easynettopo|easynettopo-gateway) ;; *) die "发现未经允许的同项目容器：$name" ;; esac
        done <<< "$allowed"
        for name in easynettopo easynettopo-gateway; do
            if docker container inspect "$name" >/dev/null 2>&1; then
                grep -Fxq "$name" <<< "$allowed" || die "同名容器不属于目标项目：$name"
                project="easynettopo"
                service="easynettopo"
                [[ "$name" != easynettopo-gateway ]] || service="gateway"
                working="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name")"
                [[ "$working" == "$DEPLOY_DIR" ]] || die "容器工作目录与本部署不符：$name"
                [[ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$name")" == "$service" ]] ||
                    die "容器服务标签与本部署不符：$name"
            fi
        done
    else
        if docker container inspect portainer >/dev/null 2>&1; then
            project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' portainer)"
            working="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' portainer)"
            [[ "$project" == portainer && "$working" == "$DEPLOY_DIR" ]] ||
                die "同名 portainer 容器属于其他部署，拒绝覆盖"
        fi
    fi
}

# 新版 Portainer 将配置放在应用的 config/.env、config/.secrets。
prepare_portainer_config() {
    local config="$BASE_DIR/config" f target
    [[ ! -L "$config" ]] || die "Portainer config 不能是符号链接"
    mkdir -p "$config"
    chmod 0700 "$config"
    for f in env secrets; do
        target="$config/.$f"
        [[ ! -L "$target" ]] || die "Portainer 配置不能是符号链接"
        if [[ ! -e "$target" ]]; then
            cp "$DEPLOY_DIR/config.$f.example" "$target"
            chmod 0600 "$target"
        fi
        [[ -f "$target" && "$(stat -f '%Lp' "$target")" == 600 ]] ||
            die "Portainer 配置必须是 0600 普通文件：$target"
    done
    PORTAINER_HTTP_PORT="$(read_value "$config/.env" PORTAINER_HTTP_PORT)"
    PORTAINER_ADMIN_PASSWORD="$(read_value "$config/.secrets" PORTAINER_ADMIN_PASSWORD)"
    # 旧统一文件值作为迁移来源，优先使用新应用配置的非空值。
    [[ -n "$PORTAINER_HTTP_PORT" ]] || PORTAINER_HTTP_PORT="$(read_global PORTAINER_HTTP_PORT)"
    [[ -n "$PORTAINER_ADMIN_PASSWORD" ]] || PORTAINER_ADMIN_PASSWORD="$(read_secret PORTAINER_ADMIN_PASSWORD)"
    validate_port "$PORTAINER_HTTP_PORT"
    if [[ -z "$PORTAINER_ADMIN_PASSWORD" ]]; then
        PORTAINER_ADMIN_PASSWORD="$(openssl rand -hex 24)" ||
            die "无法为 Portainer 生成安全管理员密码"
        [[ "${#PORTAINER_ADMIN_PASSWORD}" -eq 48 ]] || die "生成的 Portainer 密码长度错误"
        persist_secret_password "$config/.secrets" PORTAINER_ADMIN_PASSWORD "$PORTAINER_ADMIN_PASSWORD"
    fi
    [[ "${#PORTAINER_ADMIN_PASSWORD}" -ge 12 ]] ||
        die "Portainer 管理员密码至少需要 12 位"
    [[ -S /var/run/docker.sock ]] || die "Portainer 需要 /var/run/docker.sock；请在 Docker Desktop Settings > Advanced 启用默认 Docker socket"
    DEPLOY_PORTAINER_IMAGE="$PORTAINER_IMAGE"
    export PORTAINER_HTTP_PORT PORTAINER_ADMIN_PASSWORD DEPLOY_PORTAINER_IMAGE
}

prepare_easynettopo_config() {
    EASYNETTOPO_HTTP_PORT="$(read_global EASYNETTOPO_HTTP_PORT)"
    [[ -n "$EASYNETTOPO_HTTP_PORT" ]] || EASYNETTOPO_HTTP_PORT=7017
    validate_port "$EASYNETTOPO_HTTP_PORT"
    EASYNETTOPO_BIND_IP="$(read_global EASYNETTOPO_BIND_IP)"
    [[ -n "$EASYNETTOPO_BIND_IP" ]] || EASYNETTOPO_BIND_IP=0.0.0.0
    [[ "$EASYNETTOPO_BIND_IP" == 0.0.0.0 || "$EASYNETTOPO_BIND_IP" == 127.0.0.1 ]] ||
        die "macOS 默认只允许 EASYNETTOPO_BIND_IP=0.0.0.0 或 127.0.0.1"
    EASYNETTOPO_GIT_ALLOWED_HOSTS="$(read_global EASYNETTOPO_GIT_ALLOWED_HOSTS)"
    [[ -n "$EASYNETTOPO_GIT_ALLOWED_HOSTS" ]] || EASYNETTOPO_GIT_ALLOWED_HOSTS=github.com
    EASYNETTOPO_GIT_ALLOW_HTTP="$(read_global EASYNETTOPO_GIT_ALLOW_HTTP)"
    [[ -n "$EASYNETTOPO_GIT_ALLOW_HTTP" ]] || EASYNETTOPO_GIT_ALLOW_HTTP=false
    [[ "$EASYNETTOPO_GIT_ALLOW_HTTP" == true || "$EASYNETTOPO_GIT_ALLOW_HTTP" == false ]] ||
        die "无效的 EASYNETTOPO_GIT_ALLOW_HTTP"
    DEPLOY_EASYNETTOPO_IMAGE="$EASYNETTOPO_IMAGE"
    [[ "$DEPLOY_EASYNETTOPO_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/@:-]*$ ]] ||
        die "无效镜像引用"
    [[ -f "$DEPLOY_DIR/docker-compose.macos.yaml" ]] || die "缺少 macOS Compose 覆盖文件"
    EASYNETTOPO_MACOS_UID="$(id -u)"
    EASYNETTOPO_MACOS_GID="$(id -g)"
    export EASYNETTOPO_HTTP_PORT EASYNETTOPO_BIND_IP EASYNETTOPO_GIT_ALLOWED_HOSTS
    export EASYNETTOPO_GIT_ALLOW_HTTP DEPLOY_EASYNETTOPO_IMAGE EASYNETTOPO_MACOS_UID EASYNETTOPO_MACOS_GID
}

persist_secret_password() {
    local secret="$1" key="$2" value="$3" tmp line found=0
    case "$key" in PORTAINER_ADMIN_PASSWORD|EASYNETTOPO_ADMIN_PASSWORD) ;; *) die "无效的密钥名称" ;; esac
    [[ -f "$secret" && ! -L "$secret" && "$(stat -f '%Lp' "$secret")" == 600 ]] ||
        die "密钥文件必须是受保护的普通文件"
    tmp="$(mktemp "$secret.tmp.XXXXXXXX")" || die "无法创建密码临时文件"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
            printf '%s=%s\n' "$key" "$value"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$secret" > "$tmp"
    [[ "$found" -eq 1 ]] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$secret"
}

bootstrap_admin() {
    local status
    status="$(compose exec -T easynettopo wget -qO- http://127.0.0.1:8080/api/v1/auth/status)" ||
        die "无法读取管理员初始化状态"
    case "$status" in *'"initialized":true'*) return 0 ;; *'"initialized":false'*) ;; *) die "无法解析管理员初始化状态" ;; esac
    EASYNETTOPO_ADMIN_USERNAME="$(read_secret EASYNETTOPO_ADMIN_USERNAME)"
    [[ -n "$EASYNETTOPO_ADMIN_USERNAME" ]] || EASYNETTOPO_ADMIN_USERNAME=admin
    EASYNETTOPO_ADMIN_PASSWORD="$(read_secret EASYNETTOPO_ADMIN_PASSWORD)"
    if [[ -z "$EASYNETTOPO_ADMIN_PASSWORD" ]]; then
        EASYNETTOPO_ADMIN_PASSWORD="$(openssl rand -hex 24)"
        [[ "${#EASYNETTOPO_ADMIN_PASSWORD}" -eq 48 ]] || die "无法生成管理员密码"
        persist_secret_password "$SECRETS_FILE" EASYNETTOPO_ADMIN_PASSWORD "$EASYNETTOPO_ADMIN_PASSWORD"
    fi
    printf '%s\n%s\n' "$EASYNETTOPO_ADMIN_USERNAME" "$EASYNETTOPO_ADMIN_PASSWORD" |
        compose exec -T easynettopo /usr/local/bin/easynettopo admin init --stdin ||
        die "管理员初始化失败，请检查 .secrets 后重试"
    unset EASYNETTOPO_ADMIN_PASSWORD
    echo "EasyNetTopo 管理员已初始化；密码保存在 $SECRETS_FILE"
}

# 卸载也必须能解析 Compose 的 macOS UID/GID 和 Portainer secret。
if [[ "$TASK" == easynettopo ]]; then
    EASYNETTOPO_MACOS_UID="$(id -u)"
    EASYNETTOPO_MACOS_GID="$(id -g)"
    export EASYNETTOPO_MACOS_UID EASYNETTOPO_MACOS_GID
else
    PORTAINER_ADMIN_PASSWORD="$(read_value "$BASE_DIR/config/.secrets" PORTAINER_ADMIN_PASSWORD)"
    [[ -n "$PORTAINER_ADMIN_PASSWORD" ]] || PORTAINER_ADMIN_PASSWORD="$(read_secret PORTAINER_ADMIN_PASSWORD)"
    export PORTAINER_ADMIN_PASSWORD
fi
verify_ownership
if [[ "$ACTION" == uninstall ]]; then
    compose down --remove-orphans
    echo "$TASK 已卸载容器；运行数据及配置保留在 $BASE_DIR"
    exit 0
fi

case "$TASK" in
    easynettopo)
        prepare_easynettopo_config
        if [[ "$ACTION" == update && ! -f "$BASE_DIR/data/app.db" ]]; then
            die "未发现已有数据库；请先 install"
        fi
        [[ ! -L "$BASE_DIR/data" && ! -L "$BASE_DIR/ssh" ]] || die "数据目录不能是符号链接"
        mkdir -p "$BASE_DIR/data" "$BASE_DIR/ssh"
        chmod 0700 "$BASE_DIR/data" "$BASE_DIR/ssh" ;;
    portainer)
        prepare_portainer_config
        if [[ "$ACTION" == update && ! -d "$BASE_DIR/data" ]]; then
            die "未发现 Portainer 数据目录；请先 install"
        fi
        [[ ! -L "$BASE_DIR/data" ]] || die "数据目录不能是符号链接"
        mkdir -p "$BASE_DIR/data" ;;
esac
TZ="$(read_global TZ)"
[[ -n "$TZ" ]] || TZ=Asia/Shanghai
export TZ
# 从部署目录加载已有的共享 GHCR 路由模块。只在 install/update 准备好镜像变量后选站一次，
# 使 compose config / pull / up 共用同一地址；Docker Hub、本地镜像不参与轮换。
image_source_lib="$SOFTWARE_ROOT/deploy/lib/image-sources.sh"
[[ -f "$image_source_lib" && ! -L "$image_source_lib" && -O "$image_source_lib" ]] ||
    die "共享镜像来源模块缺失或所有权不安全，请先从最新 deploy 仓库同步"
# shellcheck source=../lib/image-sources.sh
source "$image_source_lib"
if [[ "$TASK" == easynettopo ]]; then
    deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_EASYNETTOPO_IMAGE ||
        die "EasyNetTopo 镜像来源解析失败"
else
    deploy_prepare_images "$SOFTWARE_ROOT" "$ENV_FILE" DEPLOY_PORTAINER_IMAGE ||
        die "Portainer 镜像来源解析失败"
fi
compose config --quiet || die "Compose 配置校验失败"
if [[ "$TASK" == easynettopo && "$DEPLOY_EASYNETTOPO_IMAGE" == easynettopo:local ]]; then
    docker image inspect easynettopo:local >/dev/null || die "本地镜像 easynettopo:local 不存在"
else
    compose pull || die "镜像拉取失败"
fi
compose up -d --remove-orphans --pull never --wait --wait-timeout 180 || die "容器启动/健康检查失败"
if [[ "$TASK" == easynettopo ]]; then
    bootstrap_admin
    echo "EasyNetTopo 已就绪：http://127.0.0.1:$EASYNETTOPO_HTTP_PORT"
else
    echo "Portainer 已启动：http://127.0.0.1:$PORTAINER_HTTP_PORT"
fi
