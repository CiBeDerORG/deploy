#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$0" "$@"
    fi

    echo "需要 root 权限执行该脚本，请使用 sudo。" >&2
    exit 1
fi

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
CONFIG_FILE="$CONFIG_DIR/frps.toml"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yaml"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
SERVICE="frps"
CONTAINER="frps"
MODE="${1:-install}"

OWNER_USER="${SUDO_USER:-$(id -un)}"
OWNER_GROUP="$(id -gn "$OWNER_USER" 2>/dev/null || id -gn)"

declare -a FRPS_TOML_ALLOW_LINES=()
declare -a FRPS_COMPOSE_PORT_LINES=()


compose() {
    docker compose "$@"
}

check_runtime() {
    command -v docker >/dev/null 2>&1 || {
        echo "未检测到 Docker，请先安装 Docker。" >&2
        exit 1
    }

    docker compose version >/dev/null 2>&1 || {
        echo "未检测到 Docker Compose Plugin。" >&2
        exit 1
    }
}

backup_clients() {
    local backup_dir backup_file

    [ -f "$DATA_DIR/clients.json" ] || {
        echo "      clients.json 不存在，跳过备份"
        return 0
    }

    backup_dir="$DATA_DIR/backup"
    backup_file="$backup_dir/clients-$(date '+%Y%m%d-%H%M%S').json"

    mkdir -p "$backup_dir"
    cp -a "$DATA_DIR/clients.json" "$backup_file"
    echo "      已备份 clients.json: $backup_file"
}

fix_permissions() {
    echo "      宿主机维护用户: $OWNER_USER:$OWNER_GROUP"

    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
    chown -R "$OWNER_USER:$OWNER_GROUP" "$CONFIG_DIR" "$DATA_DIR" "$DEPLOY_DIR"
    chmod -R u+rwX,g+rwX,o-rwx "$CONFIG_DIR" "$DATA_DIR"
    chmod -R u+rwX,g+rX,o-rwx "$DEPLOY_DIR"
    find "$CONFIG_DIR" "$DATA_DIR" -type d -exec chmod g+s {} +

    if [ -f "$CONFIG_FILE" ]; then
        chmod 0660 "$CONFIG_FILE"
    fi

    if [ -f "$COMPOSE_FILE" ]; then
        chmod 0640 "$COMPOSE_FILE"
    fi

    if [ -f "$ENV_FILE" ] && [ -f "$SECRETS_FILE" ]; then
        chown root:root "$ENV_FILE" "$SECRETS_FILE"
        chmod 0600 "$ENV_FILE" "$SECRETS_FILE"
    fi
}

load_dotenv_file() {
    local file="$1"
    local line key value
    local line_no=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"

        case "$line" in
            ''|'#'*) continue ;;
        esac

        if [[ "$line" != *=* ]]; then
            echo "配置格式错误: $file:$line_no（必须是 KEY=VALUE）" >&2
            return 1
        fi

        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"

        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "配置变量名非法: $file:$line_no: $key" >&2
            return 1
        fi

        if [ "${#value}" -gt 0 ]; then
            case "${value:0:1}" in
                '"')
                    if [ "${#value}" -lt 2 ] || [ "${value: -1}" != '"' ]; then
                        echo "配置双引号未闭合: $file:$line_no" >&2
                        return 1
                    fi
                    value="${value:1:${#value}-2}"
                    ;;
                "'")
                    if [ "${#value}" -lt 2 ] || [ "${value: -1}" != "'" ]; then
                        echo "配置单引号未闭合: $file:$line_no" >&2
                        return 1
                    fi
                    value="${value:1:${#value}-2}"
                    ;;
            esac
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
}

load_env() {
    [ -f "$ENV_FILE" ] || {
        echo "统一普通配置文件不存在: $ENV_FILE" >&2
        echo "请先在 deploy 仓库根目录执行: sudo bash deploy.sh env" >&2
        exit 1
    }

    [ -f "$SECRETS_FILE" ] || {
        echo "统一敏感配置文件不存在: $SECRETS_FILE" >&2
        echo "请先在 deploy 仓库根目录执行: sudo bash deploy.sh env" >&2
        exit 1
    }

    chown root:root "$ENV_FILE" "$SECRETS_FILE"
    chmod 0600 "$ENV_FILE" "$SECRETS_FILE"

    if grep -q $'\r' "$ENV_FILE"; then
        sed -i 's/\r$//' "$ENV_FILE"
        echo "      已自动将 $ENV_FILE 的 CRLF 行尾转换为 LF。"
    fi

    if grep -q $'\r' "$SECRETS_FILE"; then
        sed -i 's/\r$//' "$SECRETS_FILE"
        echo "      已自动将 $SECRETS_FILE 的 CRLF 行尾转换为 LF。"
    fi

    load_dotenv_file "$ENV_FILE"
    load_dotenv_file "$SECRETS_FILE"
}

validate_port_value() {
    local label="$1"
    local value="$2"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        echo "$label 必须是 1-65535 的有效端口，当前值: ${value:-<空>}" >&2
        exit 1
    fi
}

validate_scalar_ports() {
    local name

    for name in \
        FRPS_BIND_PORT \
        FRPS_DASHBOARD_PORT
    do
        validate_port_value "$name" "${!name:-}"
    done

    # FRPS vhost 内部端口固定为 80/443，bind/dashboard 不能占用。
    if [ "$FRPS_BIND_PORT" -eq "$FRPS_DASHBOARD_PORT" ] || \
       [ "$FRPS_BIND_PORT" -eq 80 ] || \
       [ "$FRPS_BIND_PORT" -eq 443 ] || \
       [ "$FRPS_DASHBOARD_PORT" -eq 80 ] || \
       [ "$FRPS_DASHBOARD_PORT" -eq 443 ]; then
        echo "FRPS 内部监听端口存在冲突：bind/dashboard 不能重复，也不能使用固定 vhost 端口 80/443。" >&2
        exit 1
    fi

    # 宿主机固定映射端口为 9080/9443，bind/dashboard 不能占用。
    if [ "$FRPS_BIND_PORT" -eq 9080 ] || \
       [ "$FRPS_BIND_PORT" -eq 9443 ] || \
       [ "$FRPS_DASHBOARD_PORT" -eq 9080 ] || \
       [ "$FRPS_DASHBOARD_PORT" -eq 9443 ]; then
        echo "FRPS bind/dashboard 不能使用固定宿主机映射端口 9080/9443。" >&2
        exit 1
    fi
}

proxy_port_conflicts_reserved() {
    local port="$1"
    local reserved

    # 代理端口同时会成为 FRPS 内部监听端口和 Docker 宿主机映射端口，
    # 因此既不能占用 FRPS 内部固定监听，也不能占用宿主机固定映射。
    for reserved in \
        "$FRPS_BIND_PORT" \
        "$FRPS_DASHBOARD_PORT" \
        80 \
        443 \
        9080 \
        9443
    do
        if [ "$port" -eq "$reserved" ]; then
            return 0
        fi
    done

    return 1
}

parse_proxy_ports() {
    local raw="${FRPS_PROXY_PORTS:-}"
    local inner item start end port
    local -a items=()
    local -A seen_items=()
    local -A seen_ports=()

    FRPS_TOML_ALLOW_LINES=()
    FRPS_COMPOSE_PORT_LINES=()

    if [[ "$raw" != \[*\] ]]; then
        echo "FRPS_PROXY_PORTS 必须是数组格式，例如：" >&2
        echo "  FRPS_PROXY_PORTS='[\"3389\",\"7100-7800\",\"8001\"]'" >&2
        exit 1
    fi

    inner="${raw#\[}"
    inner="${inner%\]}"
    inner="${inner//[[:space:]]/}"

    [ -n "$inner" ] || {
        echo "FRPS_PROXY_PORTS 不能为空数组。" >&2
        exit 1
    }

    IFS=',' read -r -a items <<< "$inner"

    for item in "${items[@]}"; do
        item="${item#\"}"
        item="${item%\"}"
        item="${item#\'}"
        item="${item%\'}"

        [ -n "$item" ] || {
            echo "FRPS_PROXY_PORTS 中存在空项。" >&2
            exit 1
        }

        if [[ -n "${seen_items[$item]:-}" ]]; then
            echo "FRPS_PROXY_PORTS 存在重复项: $item" >&2
            exit 1
        fi
        seen_items["$item"]=1

        if [[ "$item" =~ ^[0-9]+$ ]]; then
            validate_port_value "FRPS_PROXY_PORTS 单端口" "$item"

            if proxy_port_conflicts_reserved "$item"; then
                echo "FRPS_PROXY_PORTS 端口 $item 与 FRPS 固定服务端口冲突。" >&2
                exit 1
            fi

            if [[ -n "${seen_ports[$item]:-}" ]]; then
                echo "FRPS_PROXY_PORTS 端口重复或范围重叠: $item" >&2
                exit 1
            fi
            seen_ports["$item"]=1

            FRPS_TOML_ALLOW_LINES+=("    { single = $item },")
            FRPS_COMPOSE_PORT_LINES+=("      - \"$item:$item\"")
            continue
        fi

        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"

            validate_port_value "FRPS_PROXY_PORTS 范围起始端口" "$start"
            validate_port_value "FRPS_PROXY_PORTS 范围结束端口" "$end"

            if [ "$start" -gt "$end" ]; then
                echo "FRPS_PROXY_PORTS 范围起始端口不能大于结束端口: $item" >&2
                exit 1
            fi

            for ((port = start; port <= end; port++)); do
                if proxy_port_conflicts_reserved "$port"; then
                    echo "FRPS_PROXY_PORTS 范围 $item 包含 FRPS 固定服务端口 $port。" >&2
                    exit 1
                fi

                if [[ -n "${seen_ports[$port]:-}" ]]; then
                    echo "FRPS_PROXY_PORTS 存在重复或重叠端口: $port" >&2
                    exit 1
                fi
                seen_ports["$port"]=1
            done

            FRPS_TOML_ALLOW_LINES+=("    { start = $start, end = $end },")
            FRPS_COMPOSE_PORT_LINES+=("      - \"$start-$end:$start-$end\"")
            continue
        fi

        echo "FRPS_PROXY_PORTS 非法项: $item" >&2
        echo "只支持单端口或范围，例如 3389、7100-7800。" >&2
        exit 1
    done
}

replace_managed_block() {
    local file="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local block_file="$4"
    local tmp

    grep -Fxq "$begin_marker" "$file" || {
        echo "缺少动态区块开始标记: $begin_marker ($file)" >&2
        exit 1
    }

    grep -Fxq "$end_marker" "$file" || {
        echo "缺少动态区块结束标记: $end_marker ($file)" >&2
        exit 1
    }

    tmp="$(mktemp /tmp/frps-block.XXXXXX)"

    awk -v begin="$begin_marker" -v end="$end_marker" -v block="$block_file" '
        $0 == begin {
            print
            while ((getline line < block) > 0) print line
            close(block)
            skip = 1
            next
        }
        $0 == end {
            skip = 0
            print
            next
        }
        !skip { print }
    ' "$file" > "$tmp"

    cp "$tmp" "$file"
    rm -f "$tmp"
}

apply_frps_config() {
    local block tmp

    [ -f "$CONFIG_FILE" ] || {
        echo "FRPS 配置文件不存在: $CONFIG_FILE" >&2
        exit 1
    }

    block="$(mktemp /tmp/frps-toml-block.XXXXXX)"
    {
        echo "allowPorts = ["
        printf '%s\n' "${FRPS_TOML_ALLOW_LINES[@]}"
        echo "]"
    } > "$block"

    replace_managed_block \
        "$CONFIG_FILE" \
        "# BEGIN FRPS_PROXY_PORTS" \
        "# END FRPS_PROXY_PORTS" \
        "$block"

    rm -f "$block"

    tmp="$(mktemp /tmp/frps-toml.XXXXXX)"
    sed -E \
        -e "s/^bindPort = .*/bindPort = $FRPS_BIND_PORT/" \
        -e "s/^webServer\.port = .*/webServer.port = $FRPS_DASHBOARD_PORT/" \
        "$CONFIG_FILE" > "$tmp"

    cp "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

apply_compose_ports() {
    local block tmp

    [ -f "$COMPOSE_FILE" ] || {
        echo "FRPS Compose 文件不存在: $COMPOSE_FILE" >&2
        exit 1
    }

    block="$(mktemp /tmp/frps-compose-proxy-block.XXXXXX)"
    printf '%s\n' "${FRPS_COMPOSE_PORT_LINES[@]}" > "$block"

    replace_managed_block \
        "$COMPOSE_FILE" \
        "      # BEGIN FRPS_PROXY_PORTS" \
        "      # END FRPS_PROXY_PORTS" \
        "$block"

    rm -f "$block"

    grep -Fq '# FRPS_BIND_PORT' "$COMPOSE_FILE" || {
        echo "FRPS Compose 缺少 FRPS_BIND_PORT 标记: $COMPOSE_FILE" >&2
        exit 1
    }
    grep -Fq '# FRPS_DASHBOARD_PORT' "$COMPOSE_FILE" || {
        echo "FRPS Compose 缺少 FRPS_DASHBOARD_PORT 标记: $COMPOSE_FILE" >&2
        exit 1
    }

    tmp="$(mktemp /tmp/frps-compose-ports.XXXXXX)"
    sed -E \
        -e "s#^[[:space:]]*- \"[0-9]+:[0-9]+\" # FRPS_BIND_PORT\$#      - \"$FRPS_BIND_PORT:$FRPS_BIND_PORT\" # FRPS_BIND_PORT#" \
        -e "s#^[[:space:]]*- \"[0-9]+:[0-9]+\" # FRPS_DASHBOARD_PORT\$#      - \"$FRPS_DASHBOARD_PORT:$FRPS_DASHBOARD_PORT\" # FRPS_DASHBOARD_PORT#" \
        -e "s#http://127\\.0\\.0\\.1:[0-9]+/healthz#http://127.0.0.1:$FRPS_DASHBOARD_PORT/healthz#g" \
        "$COMPOSE_FILE" > "$tmp"

    cp "$tmp" "$COMPOSE_FILE"
    rm -f "$tmp"
}

apply_runtime_config() {
    load_env
    validate_scalar_ports
    parse_proxy_ports
    fix_permissions
    apply_frps_config
    apply_compose_ports

    chown "$OWNER_USER:$OWNER_GROUP" "$CONFIG_FILE" "$COMPOSE_FILE"
    chmod 0660 "$CONFIG_FILE"
    chmod 0640 "$COMPOSE_FILE"

    echo "      已根据 $ENV_FILE 更新:"
    echo "      $CONFIG_FILE"
    echo "      $COMPOSE_FILE"
}

case "$MODE" in
    apply-config)
        apply_runtime_config
        exit 0
        ;;
    install|update)
        ;;
    *)
        echo "未知参数: $MODE" >&2
        echo "支持: install / update；内部参数: apply-config" >&2
        exit 1
        ;;
esac

echo "=================================================="
if [ "$MODE" = "update" ]; then
    echo " FRPS 更新开始"
else
    echo " FRPS 安装开始"
fi
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

echo "[1/6] 检查运行环境..."
check_runtime

[ -d "$DEPLOY_DIR" ] || {
    echo "部署目录不存在: $DEPLOY_DIR" >&2
    exit 1
}

echo "[2/6] 根据统一 .env 同步 FRPS TOML/YAML 端口..."
apply_runtime_config

cd "$DEPLOY_DIR"

echo "[3/6] 校验 Compose 配置..."
if ! compose config >/dev/null; then
    echo "Compose 配置校验失败。" >&2
    echo "请检查 $ENV_FILE、$SECRETS_FILE 和 FRPS_PROXY_PORTS。" >&2
    exit 1
fi

echo "[4/6] 拉取 FRPS 镜像..."
compose pull "$SERVICE"

if [ "$MODE" = "update" ]; then
    echo "[5/6] 停止旧容器、备份并更新 FRPS..."
    compose stop "$SERVICE" >/dev/null 2>&1 || true
    backup_clients
    compose up -d --no-deps "$SERVICE"
else
    echo "[5/6] 启动 FRPS..."
    compose up -d "$SERVICE"
fi

echo "[6/6] 等待 FRPS 启动..."

for _ in $(seq 1 30); do
    STATUS="$(docker inspect \
        --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$CONTAINER" 2>/dev/null || true)"

    case "$STATUS" in
        healthy|running)
            echo
            echo "=================================================="
            if [ "$MODE" = "update" ]; then
                echo " FRPS 更新成功"
            else
                echo " FRPS 安装成功"
            fi
            echo " 状态: $STATUS"
            echo " 端口数组: $FRPS_PROXY_PORTS"
            echo " 宿主机维护用户: $OWNER_USER:$OWNER_GROUP"
            echo "=================================================="
            compose ps
            exit 0
            ;;
        unhealthy|exited|dead)
            echo
            echo "FRPS 启动失败，当前状态: $STATUS" >&2
            compose logs --tail=100 "$SERVICE" || true
            exit 1
            ;;
    esac

    sleep 2
done

echo "等待 FRPS 健康检查超时。" >&2
compose ps || true
compose logs --tail=100 "$SERVICE" || true
exit 1
