#!/usr/bin/env bash
# 隔离测试正式 deploy 入口，不拉取镜像、不启动真实容器。
set -Eeuo pipefail
(( EUID == 0 )) || { echo "请使用 root 运行隔离测试" >&2; exit 1; }
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export SOFTWARE_ROOT="$tmp/software" DEPLOY_TEST_DIR="$tmp"
mkdir -p "$tmp/bin" "$SOFTWARE_ROOT"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
    info) exit 0 ;;
    ps) if [[ -e "$DEPLOY_TEST_DIR/installed" ]]; then echo easyhostagent; fi; exit 0 ;;
    container)
        [[ "$2" == inspect && -e "$DEPLOY_TEST_DIR/installed" ]] ;;
    inspect)
        if [[ "$*" == *com.docker.compose.service* ]]; then
            echo easyhostagent
        elif [[ "$*" == *com.docker.compose.project.working_dir* ]]; then
            echo "$SOFTWARE_ROOT/easyhostagent/deploy"
        else
            exit 1
        fi ;;
    compose)
        printf '%s\n' "$*" >> "$DEPLOY_TEST_DIR/docker-calls"
        case " $* " in
            *' up -d '*) touch "$DEPLOY_TEST_DIR/installed" ;;
            *' down --remove-orphans '*) rm -f "$DEPLOY_TEST_DIR/installed" ;;
        esac ;;
    *) echo "不允许的 Docker 操作：$*" >&2; exit 47 ;;
esac
MOCK
chmod 0755 "$tmp/bin/docker"

cd "$repo"
bash deploy.sh list | grep -F easyhostagent >/dev/null
bash deploy.sh env >/dev/null
envfile="$SOFTWARE_ROOT/deploy/.env"
grep -qx 'EASYHOSTAGENT_IMAGE=ghcr.io/cibederorg/easyhostagent:feat-docker-app-store' "$envfile"
grep -qx 'EASYHOSTAGENT_TRANSPORT=https' "$envfile"
grep -qx 'EASYHOSTAGENT_LISTEN_ADDRESS=0.0.0.0:7018' "$envfile"
data="$tmp/agent-data"
mkdir -m 0700 "$data"
sed -i "s#^EASYHOSTAGENT_DATA_DIR=.*#EASYHOSTAGENT_DATA_DIR=$data#" "$envfile"
deploy_app() {
    bash deploy.sh easyhostagent "$1" > "$tmp/$1.log" 2>&1 ||
        { cat "$tmp/$1.log" >&2; return 1; }
}
deploy_app install
test -e "$tmp/installed"
grep -F ' compose ' "$tmp/docker-calls" >/dev/null || true
grep -F ' pull' "$tmp/docker-calls" >/dev/null
grep -F ' up -d --pull never --wait ' "$tmp/docker-calls" >/dev/null
grep -F 'ghcr.io/cibederorg/easyhostagent:feat-docker-app-store' "$tmp/install.log" >/dev/null
test "$(stat -c '%u:%a' "$data")" = 0:700

printf '%s' 'existing-identity' > "$data/identity.json"
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http/' "$envfile"
sed -i 's/^EASYHOSTAGENT_LISTEN_ADDRESS=.*/EASYHOSTAGENT_LISTEN_ADDRESS=127.0.0.1:7020/' "$envfile"
sed -i 's#^EASYHOSTAGENT_APP_GRANTS=.*#EASYHOSTAGENT_APP_GRANTS=11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222#' "$envfile"
deploy_app update
test "$(cat "$data/identity.json")" = existing-identity

# 无效协议、无效 IP、重复键均不得触发 Compose 或修改数据。
calls="$(wc -l < "$tmp/docker-calls")"
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http;false/' "$envfile"
if bash deploy.sh easyhostagent update >/dev/null 2>&1; then exit 1; fi
sed -i 's/^EASYHOSTAGENT_TRANSPORT=.*/EASYHOSTAGENT_TRANSPORT=http/' "$envfile"
printf 'EASYHOSTAGENT_TRANSPORT=https\n' >> "$envfile"
if bash deploy.sh easyhostagent update >/dev/null 2>&1; then exit 1; fi
sed -i '$d' "$envfile"
test "$(wc -l < "$tmp/docker-calls")" = "$calls"

deploy_app uninstall
test ! -e "$tmp/installed"
test "$(cat "$data/identity.json")" = existing-identity
test -d "$SOFTWARE_ROOT/easyhostagent"
test -f "$envfile"
echo "EasyHostAgent GHCR 单容器安装、更新、配置校验、数据保留、卸载测试通过"
