#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail
MODE="${1:-install}"
case "$MODE" in install|update) ;; *) echo "仅支持 install/update" >&2; exit 1 ;; esac
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SOFTWARE_ROOT="$(cd -- "$BASE_DIR/.." && pwd)"
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
SECRETS_FILE="$SOFTWARE_ROOT/deploy/.secrets"
# shellcheck source=./lib.sh
source "$DEPLOY_DIR/lib.sh"
require_root "$@"
check_docker
load_global_config

MIHOMO_MIXED_PORT="${MIHOMO_MIXED_PORT:-7011}"
# Compatibility: the existing API_PORT now publishes the Web/Agent, not core API.
MIHOMO_API_PORT="${MIHOMO_API_PORT:-7012}"
MIHOMO_CORE_API_PORT="${MIHOMO_CORE_API_PORT:-7013}"
MIHOMO_PROXY_BIND_IP="${MIHOMO_PROXY_BIND_IP:-127.0.0.1}"
MIHOMO_API_BIND_IP="${MIHOMO_API_BIND_IP:-0.0.0.0}"
MIHOMO_CORE_API_BIND_IP="${MIHOMO_CORE_API_BIND_IP:-0.0.0.0}"
MIHOMO_WEB_ORIGIN="${MIHOMO_WEB_ORIGIN:-}"
for key in MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT; do
    validate_port "$key" "${!key}"
done
[ "$MIHOMO_MIXED_PORT" != "$MIHOMO_API_PORT" ] &&
[ "$MIHOMO_MIXED_PORT" != "$MIHOMO_CORE_API_PORT" ] &&
[ "$MIHOMO_API_PORT" != "$MIHOMO_CORE_API_PORT" ] ||
    fail "代理、Web/Agent、内核 API 宿主机端口必须互不相同"
for key in MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP; do
    validate_ipv4 "$key" "${!key}"
done
# Do not change a nonempty user-configured secret; keep legacy API credential.
ensure_hex_secret MIHOMO_API_SECRET
ensure_hex_secret MIHOMO_CONTROL_TOKEN
MIHOMO_PROXY_USER="${MIHOMO_PROXY_USER:-deploy}"
NEW_DATA="$BASE_DIR/data/all-in-one"
LEGACY_CONFIG="$BASE_DIR/data/config.yaml"
export MIHOMO_MIXED_PORT MIHOMO_API_PORT MIHOMO_CORE_API_PORT
export MIHOMO_PROXY_BIND_IP MIHOMO_API_BIND_IP MIHOMO_CORE_API_BIND_IP
export MIHOMO_API_SECRET MIHOMO_CONTROL_TOKEN TZ

verify_container_owner mihomo mihomo
if [ "$MODE" = update ]; then
    docker container inspect mihomo >/dev/null 2>&1 ||
        fail "未找到 Mihomo 容器，请先运行 sudo bash deploy.sh mihomo"
fi

install -d -m 0700 "$BASE_DIR/data" "$NEW_DATA" "$NEW_DATA/profiles"
if [ -e "$NEW_DATA/profiles/index.json" ] || [ -e "$NEW_DATA/active.yaml" ]; then
    [ -f "$NEW_DATA/profiles/index.json" ] && [ -f "$NEW_DATA/active.yaml" ] ||
        fail "完整版数据存在但不完整，拒绝覆盖：$NEW_DATA"
    echo "已存在完整版配置：不修改 Agent Profiles 或 active.yaml。"
else
    if [ -f "$LEGACY_CONFIG" ]; then
        backup_dir="$BASE_DIR/data/backup/pre-all-in-one"
        install -d -m 0700 "$backup_dir"
        if [ ! -f "$backup_dir/config.yaml" ]; then
            cp -p "$LEGACY_CONFIG" "$backup_dir/config.yaml"
            chmod 0600 "$backup_dir/config.yaml"
        fi
        # Copy rather than modify the old config. The new image includes its UI.
        sed '/^external-ui:/d; /^external-ui-url:/d' "$LEGACY_CONFIG" > "$NEW_DATA/profiles/deploy-initial.yaml"
        echo "旧配置已备份并复制为完整版 Profile；原文件不删除、不改密码。"
    else
        ensure_hex_secret MIHOMO_PROXY_PASSWORD
        cp "$DEPLOY_DIR/profile.example.yaml" "$NEW_DATA/profiles/deploy-initial.yaml"
        auth_entry="$(yaml_single_quote_scalar "$MIHOMO_PROXY_USER:$MIHOMO_PROXY_PASSWORD")"
        printf '\nauthentication:\n  - %s\n' "$auth_entry" >> "$NEW_DATA/profiles/deploy-initial.yaml"
        echo "已创建完整版初始 Profile。"
    fi
    # A global merge Profile keeps browser CORS when activating later subscriptions.
    write_web_cors "$MIHOMO_API_PORT" "$MIHOMO_WEB_ORIGIN" > "$NEW_DATA/profiles/deploy-web-cors.yaml"
    cp "$NEW_DATA/profiles/deploy-initial.yaml" "$NEW_DATA/active.yaml"
    # At boot Agent starts active.yaml directly, before first profile activation.
    if ! grep -q '^external-controller-cors:' "$NEW_DATA/active.yaml"; then
        printf '\n' >> "$NEW_DATA/active.yaml"
        cat "$NEW_DATA/profiles/deploy-web-cors.yaml" >> "$NEW_DATA/active.yaml"
    else
        echo "旧配置已有 CORS：请检查其来源是否包含新 Web 地址；再次激活 Profile 后会合并 Web overlay。"
    fi
    # Preserve legacy/initial proxy authentication across *new* remote profiles.
    # Without this overlay, importing a subscription could unintentionally drop
    # auth for proxy-net clients. Extract bytes from the original Profile source.
    extract_legacy_authentication "$NEW_DATA/profiles/deploy-initial.yaml" > "$NEW_DATA/profiles/deploy-proxy-auth.yaml"
    if [ ! -s "$NEW_DATA/profiles/deploy-proxy-auth.yaml" ]; then
        rm -f "$NEW_DATA/profiles/deploy-proxy-auth.yaml"
    fi
    cat > "$NEW_DATA/profiles/index.json" <<'EOF_INDEX'
[
  {"id":"deploy-initial","name":"Deploy initial or migrated profile","type":"local","updatedAt":0},
  {"id":"deploy-web-cors","name":"Deploy browser origin compatibility","type":"merge","enabled":true,"updatedAt":0}
EOF_INDEX
    if [ -f "$NEW_DATA/profiles/deploy-proxy-auth.yaml" ]; then
        # Insert before the final closing bracket; content here is static JSON,
        # and credentials only live in the independent chmod 0600 YAML file.
        sed -i '$s/}$/},/' "$NEW_DATA/profiles/index.json"
        printf '  {"id":"deploy-proxy-auth","name":"Deploy persistent proxy authentication","type":"merge","enabled":true,"updatedAt":0}\n' >> "$NEW_DATA/profiles/index.json"
    fi
    printf ']\n' >> "$NEW_DATA/profiles/index.json"
    printf '{"activeId":"deploy-initial"}\n' > "$NEW_DATA/profiles/state.json"
    chmod 0600 "$NEW_DATA/active.yaml" "$NEW_DATA/profiles/"*
fi

bash "$DEPLOY_DIR/proxy-network.sh" ensure
cd "$DEPLOY_DIR"
compose() { docker compose -f "$DEPLOY_DIR/docker-compose.yaml" "$@"; }
compose config --quiet || fail "Compose 配置校验失败"
# Pull and smoke-test new official image before replacing the running old container.
compose pull || fail "完整版镜像拉取失败；旧容器不受影响。"
compose run --rm --no-deps --entrypoint /bin/sh mihomo -ec \
    'test -x /usr/local/bin/mihomo && test -f /app/server/index.mjs && test -f /app/ui-dist/index.html' ||
    fail "官方镜像检查失败；旧容器不受影响。"
echo "准备替换 mihomo 容器；旧 config.yaml 与备份均保留。"
compose up -d --force-recreate --wait --wait-timeout 120 ||
    fail "完整版 Web 未通过健康检查，执行 docker logs mihomo 查看原因；不会删除旧数据。"
# Agent UI can be healthy even if its supervised kernel has not started.
for attempt in $(seq 1 30); do
    if docker exec mihomo node -e \
        'fetch("http://127.0.0.1:9090/version",{headers:{Authorization:"Bearer "+process.env.CLASH_SECRET}}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' \
        >/dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 30 ]; then
        fail "Web 已运行但内核未就绪；查看 docker logs mihomo 和网页内核状态。"
    fi
    sleep 1
done
echo "MetaCubeXD 完整版 Web/Agent：http://<NAS-IP>:$MIHOMO_API_PORT/（不再使用 /ui/）"
echo "内核 API：$MIHOMO_CORE_API_BIND_IP:$MIHOMO_CORE_API_PORT；代理：$MIHOMO_PROXY_BIND_IP:$MIHOMO_MIXED_PORT"
echo "proxy-net 服务名不变：mihomo:7890；持久化数据：$NEW_DATA"
echo "注意：官方 CONTROL_TOKEN 会注入浏览器，不能当网页登录密码；请用防火墙/可信私网限制 Web 来源。"
compose ps
