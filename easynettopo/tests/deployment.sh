#!/usr/bin/env bash
# 在临时软件根目录执行正式入口，替身只记录 Docker 动作和镜像选择。
set -Eeuo pipefail
(( EUID == 0 )) || { echo "请用 sudo 运行此隔离测试" >&2; exit 1; }
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export SOFTWARE_ROOT="$tmp/software" DEPLOY_TEST_DIR="$tmp" PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
if env | grep -q '^EASYNETTOPO_ADMIN_'; then exit 43; fi
case "$1 ${2:-}" in
    'compose version'|'image inspect') exit 0 ;;
    'container inspect') exit 1 ;;
esac
case "$1" in
    info|ps) exit 0 ;;
    compose) ;;
    *) exit 44 ;;
esac
[[ "$1 $2 $3" == 'compose --env-file /dev/null' ]]
printf '%s %s %s\n' "$DEPLOY_EASYNETTOPO_IMAGE" "$EASYNETTOPO_BIND_IP" "$*" >> "$DEPLOY_TEST_DIR/docker-calls"
case " $* " in
    *' up -d '*)
        compose_file="$SOFTWARE_ROOT/easynettopo/deploy/docker-compose.yaml"
        grep -Fqx '      - "${EASYNETTOPO_BIND_IP:-0.0.0.0}:${EASYNETTOPO_HTTP_PORT:-7017}:8080"' "$compose_file"
        printf '%s:%s:8080 %s %s %s\n' "$EASYNETTOPO_BIND_IP" "$EASYNETTOPO_HTTP_PORT" \
            "$EASYNETTOPO_GIT_ALLOWED_HOSTS" "$EASYNETTOPO_GIT_ALLOW_HTTP" "$TZ" > "$DEPLOY_TEST_DIR/compose-settings"
        [[ -z "${EASYNETTOPO_TEST_APP_ONLY:-}" ]]
        [[ "${EASYNETTOPO_HOOK_TOKEN:-}" == "${EXPECTED_HOOK_TOKEN:-}" ]] ;;
    *' exec -T easynettopo wget '*)
        if [[ -e "$DEPLOY_TEST_DIR/initialized" ]]; then echo '{"initialized":true}'; else echo '{"initialized":false}'; fi ;;
    *' admin init --stdin '*)
        cat > "$DEPLOY_TEST_DIR/stdin"
        [[ ! -e "$DEPLOY_TEST_DIR/initialized" ]]
        if [[ -n "${EASYNETTOPO_TEST_BINARY:-}" ]]; then
            EASYNETTOPO_DATABASE_PATH="$SOFTWARE_ROOT/easynettopo/data/app.db" "$EASYNETTOPO_TEST_BINARY" admin init --stdin < "$DEPLOY_TEST_DIR/stdin"
        else
            touch "$SOFTWARE_ROOT/easynettopo/data/app.db"
        fi
        touch "$DEPLOY_TEST_DIR/initialized" ;;
esac
MOCK
chmod +x "$tmp/bin/docker"

cd "$repo"
bash deploy.sh list | grep -F easynettopo > /dev/null
bash deploy.sh env >/dev/null
settings="$SOFTWARE_ROOT/deploy/.env"
secrets="$SOFTWARE_ROOT/deploy/.secrets"
sed -i 's/^DOCKER_IMAGE_SOURCE=.*/DOCKER_IMAGE_SOURCE=mirror/' "$settings"
# 模拟遗留镜像值；新的部署入口必须移除并忽略该键。
printf 'EASYNETTOPO_IMAGE=ghcr.io/cibederorg/easynettopo:obsolete\n' >> "$settings"
grep -qx 'EASYNETTOPO_BIND_IP=0.0.0.0' "$settings"
password='密 码#= "x" @$()!'\'''
printf 'EASYNETTOPO_ADMIN_USERNAME =operator_01\r\nEASYNETTOPO_ADMIN_PASSWORD="%s"\r\nOTHER_TEST_KEY=keep\n' "$password" > "$secrets"
deploy_app() { bash deploy.sh easynettopo "$1" >> "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; return 1; }; }
assert_compose_settings() {
    local actual
    actual="$(cat "$tmp/compose-settings")"
    [[ "$actual" == "$1" ]] || { printf 'Compose 配置预期为 %s，实际为 %s\n' "$1" "$actual" >&2; return 1; }
}
deploy_app install
assert_compose_settings '0.0.0.0:7017:8080 github.com false Asia/Shanghai'
! grep -Eq '^[[:space:]]*EASYNETTOPO_IMAGE[[:space:]]*=' "$settings"
grep -Fxq 'EASYNETTOPO_IMAGE=ghcr.io/cibederorg/easynettopo:main' "$SOFTWARE_ROOT/deploy/lib/versions.env"
printf 'operator_01\n%s\n' "$password" | cmp - "$tmp/stdin"
grep -F 'ghcr.dockerproxy.net/cibederorg/easynettopo:main 0.0.0.0 ' "$tmp/docker-calls" > /dev/null
if grep -F -- "$password" "$tmp/docker-calls" "$tmp/output" >/dev/null; then exit 1; fi
sed -i '/EASYNETTOPO_ADMIN_PASSWORD/c\EASYNETTOPO_ADMIN_PASSWORD=' "$secrets"
sed -i -e 's/^EASYNETTOPO_BIND_IP=.*/EASYNETTOPO_BIND_IP=127.0.0.2/' \
    -e 's/^EASYNETTOPO_HTTP_PORT=.*/EASYNETTOPO_HTTP_PORT=17400/' \
    -e 's/^TZ=.*/TZ=UTC/' "$settings"
app_settings="$SOFTWARE_ROOT/easynettopo/config/.env"
cat > "$app_settings" <<'SETTINGS'
EASYNETTOPO_HTTP_PORT=17401
EASYNETTOPO_BIND_IP=127.0.0.1
EASYNETTOPO_GIT_ALLOWED_HOSTS=gitea.example.org:3000
EASYNETTOPO_GIT_ALLOW_HTTP=true
TZ=Europe/Madrid
DOCKER_IMAGE_SOURCE=original
EASYNETTOPO_IMAGE=ignored:local
EASYNETTOPO_TEST_APP_ONLY=ignored
SETTINGS
export EXPECTED_HOOK_TOKEN=0123456789abcdef0123456789abcdef
sed -i "s/^EASYNETTOPO_HOOK_TOKEN=.*/EASYNETTOPO_HOOK_TOKEN=$EXPECTED_HOOK_TOKEN/" "$secrets"
printf 'EASYNETTOPO_HOOK_TOKEN=ignored\n' >> "$SOFTWARE_ROOT/easynettopo/config/.secrets"
# 即使旧 .env 包含空格格式的自定义版本，也必须继续只读取仓库清单。
printf 'EASYNETTOPO_IMAGE = "easynettopo:local"\n' >> "$settings"
deploy_app update
assert_compose_settings '127.0.0.1:17401:8080 gitea.example.org:3000 true UTC'
! grep -Eq '^[[:space:]]*EASYNETTOPO_IMAGE[[:space:]]*=' "$settings"
grep -F 'gh-proxy.com/docker/ghcr.io/cibederorg/easynettopo:main 127.0.0.1 ' "$tmp/docker-calls" >/dev/null
sed -i 's/^EASYNETTOPO_BIND_IP=.*/EASYNETTOPO_BIND_IP=300.168.1.4/' "$app_settings"
if bash deploy.sh easynettopo install > "$tmp/invalid-ip-output" 2>&1; then
    echo '无效监听 IPv4 未被拒绝' >&2
    exit 1
fi
grep -F 'EASYNETTOPO_BIND_IP 含无效的 IPv4 地址段' "$tmp/invalid-ip-output" >/dev/null
sed -i 's/^EASYNETTOPO_BIND_IP=.*/EASYNETTOPO_BIND_IP=127.0.0.1/' "$app_settings"
test "$(grep -c ' admin init --stdin$' "$tmp/docker-calls")" -eq 1
grep -qx 'EASYNETTOPO_ADMIN_PASSWORD=' "$secrets"
deploy_app uninstall
test -f "$SOFTWARE_ROOT/easynettopo/data/app.db"
test -d "$SOFTWARE_ROOT/easynettopo/ssh"
test "$(cat "$SOFTWARE_ROOT/deploy/state/image-mirror.last")" = ghproxy

# 老安装只保留全局配置，直接调用应用脚本时也能使用它；应用只声明部分字段时逐项回退。
mv "$app_settings" "$tmp/saved-app-settings"
bash "$SOFTWARE_ROOT/easynettopo/deploy/update.sh" >> "$tmp/output" 2>&1
assert_compose_settings '127.0.0.2:17400:8080 github.com false UTC'
printf 'EASYNETTOPO_HTTP_PORT=17402\n' > "$app_settings"
bash "$SOFTWARE_ROOT/easynettopo/deploy/update.sh" >> "$tmp/output" 2>&1
assert_compose_settings '127.0.0.2:17402:8080 github.com false UTC'
printf 'EASYNETTOPO_HOOK_TOKEN=wrong-file\n' >> "$app_settings"
if bash "$SOFTWARE_ROOT/easynettopo/deploy/update.sh" > "$tmp/misplaced-token" 2>&1; then
    echo '普通应用配置不应接收 Hook Token' >&2
    exit 1
fi
grep -Fq 'EASYNETTOPO_HOOK_TOKEN 只能写在 .secrets' "$tmp/misplaced-token"
mv "$tmp/saved-app-settings" "$app_settings"
unset EXPECTED_HOOK_TOKEN

# 模拟只有空数据库、没有管理员的中断现场，以及三种空/缺省凭据形式。
for blank in 'EASYNETTOPO_ADMIN_PASSWORD =' 'EASYNETTOPO_ADMIN_PASSWORD=""' missing; do
    rm -f "$tmp/initialized" "$SOFTWARE_ROOT/easynettopo/data/app.db"
    touch "$SOFTWARE_ROOT/easynettopo/data/app.db"
    printf "EASYNETTOPO_ADMIN_USERNAME=''\nOTHER_TEST_KEY=keep\n" > "$secrets"
    if [[ "$blank" != missing ]]; then echo "$blank" >> "$secrets"; fi
    deploy_app install
    grep -qx 'admin' "$tmp/stdin"
    generated="$(sed -n 's/^EASYNETTOPO_ADMIN_PASSWORD=//p' "$secrets")"
    [[ "$generated" =~ ^[[:xdigit:]]{48}$ ]]
    grep -qx 'OTHER_TEST_KEY=keep' "$secrets"
    printf 'admin\n%s\n' "$generated" | cmp - "$tmp/stdin"
    test "$(stat -c %a "$secrets")" = 600
    [[ "$(grep -c '^EASYNETTOPO_ADMIN_PASSWORD' "$secrets")" = 1 ]]
    deploy_app install
    grep -qx "EASYNETTOPO_ADMIN_PASSWORD=$generated" "$secrets"
done

# 多个遗留镜像键也应被统一清理，不能覆盖 versions.env 的仓库版本。
printf 'EASYNETTOPO_IMAGE=easynettopo:local\nEASYNETTOPO_IMAGE=other:tag\n' >> "$settings"
deploy_app install
! grep -Eq '^[[:space:]]*EASYNETTOPO_IMAGE[[:space:]]*=' "$settings"
grep -Fxq 'EASYNETTOPO_IMAGE=ghcr.io/cibederorg/easynettopo:main' "$SOFTWARE_ROOT/deploy/lib/versions.env"
printf '%s\n' 'EasyNetTopo 安装、更新、卸载、应用配置优先级、凭据保留与镜像轮换通过'
