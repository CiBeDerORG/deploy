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
printf '%s %s %s\n' "$DEPLOY_EASYNETTOPO_IMAGE" "$DEPLOY_EASYNETTOPO_GATEWAY_IMAGE" "$*" >> "$DEPLOY_TEST_DIR/docker-calls"
case " $* " in
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
password='密 码#= "x" @$()!'\'''
printf 'EASYNETTOPO_ADMIN_USERNAME =operator_01\r\nEASYNETTOPO_ADMIN_PASSWORD="%s"\r\nOTHER_TEST_KEY=keep\n' "$password" > "$secrets"
deploy_app() { bash deploy.sh easynettopo "$1" >> "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; return 1; }; }
deploy_app install
printf 'operator_01\n%s\n' "$password" | cmp - "$tmp/stdin"
grep -F 'ghcr.dockerproxy.net/cibederorg/easynettopo:feat-docker-app-store caddy:2.10-alpine ' "$tmp/docker-calls" > /dev/null
if grep -F -- "$password" "$tmp/docker-calls" "$tmp/output" >/dev/null; then exit 1; fi
sed -i '/EASYNETTOPO_ADMIN_PASSWORD/c\EASYNETTOPO_ADMIN_PASSWORD=' "$secrets"
deploy_app update
grep -F 'gh-proxy.com/docker/ghcr.io/cibederorg/easynettopo:feat-docker-app-store caddy:2.10-alpine ' "$tmp/docker-calls" >/dev/null
test "$(grep -c ' admin init --stdin$' "$tmp/docker-calls")" -eq 1
grep -qx 'EASYNETTOPO_ADMIN_PASSWORD=' "$secrets"
deploy_app uninstall
test -f "$SOFTWARE_ROOT/easynettopo/data/app.db"
test -d "$SOFTWARE_ROOT/easynettopo/ssh"
test "$(cat "$SOFTWARE_ROOT/deploy/state/image-mirror.last")" = ghproxy

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

sed -i 's|^EASYNETTOPO_IMAGE=.*|EASYNETTOPO_IMAGE=easynettopo:local|' "$settings"
before="$(cat "$SOFTWARE_ROOT/deploy/state/image-mirror.last")"
deploy_app install
grep -F 'easynettopo:local caddy:2.10-alpine ' "$tmp/docker-calls" | grep -F ' pull gateway' >/dev/null
test "$before" = "$(cat "$SOFTWARE_ROOT/deploy/state/image-mirror.last")"
printf '%s\n' 'EasyNetTopo 安装、更新、卸载、凭据保留与镜像轮换通过'
