#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
# 调用生产配置入口，所有读写都落在临时目录，无需 sudo 或 Docker。
source <(sed '/^initialize_paths$/,$d' "$repo/deploy.sh")
run_root() { if [[ $1 == chown ]]; then return 0; fi; "$@"; }
sync_shared_libraries() { :; }
fail() { echo "配置迁移回归失败：$1" >&2; exit 1; }

setup() {
    set_software_root "$tmp/$1"
    GLOBAL_ENV_EXAMPLE="$tmp/template.env"
    GLOBAL_SECRETS_EXAMPLE="$tmp/template.secrets"
    GLOBAL_ENV_CREATED=0 GLOBAL_SECRETS_CREATED=0 GLOBAL_ENV_UPDATED=0
    mkdir -p "$GLOBAL_ENV_DIR"
    printf '# template\nSOFTWARE_ROOT=/opt/software\nAPP_PORT=1234\n' > "$GLOBAL_ENV_EXAMPLE"
    printf '# credentials\nFRPS_DASHBOARD_USER=admin\nFRPS_DASHBOARD_PASSWORD=\n' > "$GLOBAL_SECRETS_EXAMPLE"
}
run_env() { ensure_global_env > "$tmp/output" 2>&1; }
unique_key() {
    [[ $(grep -Ec "^[[:space:]]*$2[[:space:]]*=" "$1") == 1 ]] || fail "配置键不唯一：$2"
}
secret=$(cat <<'LITERAL'
空 格 "单引号'" & /\ $d #尾部
LITERAL
)

setup first
mkdir -p "$SOFTWARE_ROOT/a/deploy" "$SOFTWARE_ROOT/b/deploy"
printf 'SOFTWARE_ROOT=/旧位置/a\n APP_PORT =5678\nFRPS_DASHBOARD_USER=旧用户\n   FRPS_DASHBOARD_PASSWORD =%s\n' "$secret" > "$SOFTWARE_ROOT/a/deploy/.env"
printf 'SOFTWARE_ROOT=/旧位置/b\nAPP_PORT="5678"\nEXTRA=extra\n' > "$SOFTWARE_ROOT/b/deploy/.env"
run_env || fail "首次合并失败"
unique_key "$GLOBAL_ENV" APP_PORT
unique_key "$GLOBAL_ENV" SOFTWARE_ROOT
grep -Fqx "SOFTWARE_ROOT=$SOFTWARE_ROOT" "$GLOBAL_ENV" || fail "旧业务文件覆盖了选定的软件根目录"
grep -Eq '^[[:space:]]*APP_PORT[[:space:]]*="?5678"?$' "$GLOBAL_ENV" || fail "旧端口被模板覆盖"
grep -Fqx 'EXTRA=extra' "$GLOBAL_ENV" || fail "旧文件额外项丢失"
grep -Fqx 'FRPS_DASHBOARD_USER=旧用户' "$GLOBAL_SECRETS" || fail "新模板默认用户名覆盖了旧值"
grep -Fqx "   FRPS_DASHBOARD_PASSWORD =$secret" "$GLOBAL_SECRETS" || fail "敏感值发生变化"
! grep -Fq 'FRPS_DASHBOARD' "$GLOBAL_ENV" || fail "普通配置仍含凭据"
! grep -Fq -- "$secret" "$tmp/output" || fail "日志泄露了值"
[[ $(stat -c %a "$GLOBAL_SECRETS") == 600 ]] || fail "密钥文件权限不正确"
cp "$GLOBAL_ENV" "$tmp/expected"; cp "$GLOBAL_SECRETS" "$tmp/expected-secret"
printf 'APP_PORT=9999\n' > "$SOFTWARE_ROOT/a/deploy/.env"
REQUESTED_SOFTWARE_ROOT="$SOFTWARE_ROOT" initialize_paths || fail "第二次执行时统一配置无法定位"
run_env && cmp -s "$GLOBAL_ENV" "$tmp/expected" && cmp -s "$GLOBAL_SECRETS" "$tmp/expected-secret" || fail "重试导入了旧备份"

setup existing
printf 'FRPS_DASHBOARD_USER=old\nFRPS_DASHBOARD_PASSWORD=%s\nGITHUB_RUNNER_TOKEN=%s\nPORTAINER_ADMIN_PASSWORD=%s\n' "$secret" "$secret" "$secret" > "$GLOBAL_ENV"
printf '  FRPS_DASHBOARD_USER = admin with spaces \nFRPS_DASHBOARD_PASSWORD=""\n GITHUB_RUNNER_TOKEN =\x27\x27\nPORTAINER_ADMIN_PASSWORD=\n' > "$GLOBAL_SECRETS"
run_env || fail "迁移引号空值失败"
grep -Fqx '  FRPS_DASHBOARD_USER = admin with spaces ' "$GLOBAL_SECRETS" || fail "已有非空值被覆盖"
for key in FRPS_DASHBOARD_PASSWORD GITHUB_RUNNER_TOKEN PORTAINER_ADMIN_PASSWORD; do
    unique_key "$GLOBAL_SECRETS" "$key"
    grep -Fqx "$key=$secret" "$GLOBAL_SECRETS" || fail "空值填充失败：$key"
done

setup explicit-empty
printf 'FRPS_DASHBOARD_USER=""\n' > "$GLOBAL_ENV"
run_env || fail "无法迁移显式空值"
grep -Fqx 'FRPS_DASHBOARD_USER=""' "$GLOBAL_SECRETS" || fail "模板默认值覆盖了旧用户显式空值"

setup conflict
mkdir -p "$SOFTWARE_ROOT/a/deploy" "$SOFTWARE_ROOT/b/deploy"
printf 'APP_PORT=0012\n' > "$SOFTWARE_ROOT/a/deploy/.env"
printf ' APP_PORT =12\n' > "$SOFTWARE_ROOT/b/deploy/.env"
if run_env; then fail "未报告来自两个旧文件的冲突"; fi
[[ ! -e "$GLOBAL_ENV" && ! -e "$GLOBAL_SECRETS" ]] || fail "冲突时留下了半成品"
grep -Fqx 'APP_PORT=0012' "$SOFTWARE_ROOT/a/deploy/.env" || fail "冲突时修改了旧文件"
printf 'APP_PORT=0012\n' > "$SOFTWARE_ROOT/b/deploy/.env"
run_env || fail "修复冲突后无法重试"
grep -Fqx 'APP_PORT=0012' "$GLOBAL_ENV" || fail "端口文本被改写"

setup previous
printf 'SOFTWARE_ROOT=%s\nAPP_PORT=1234\n' "$SOFTWARE_ROOT" > "$GLOBAL_ENV"
printf '\n# migrated from %s/a/deploy/.env\nSOFTWARE_ROOT=/old\nAPP_PORT=4567\nLEGACY=keep\n' "$SOFTWARE_ROOT" >> "$GLOBAL_ENV"
REQUESTED_SOFTWARE_ROOT="$SOFTWARE_ROOT" initialize_paths || fail "旧版追加的业务根目录阻止了修复"
run_env || fail "无法恢复旧版追加的模板重复项"
unique_key "$GLOBAL_ENV" APP_PORT
grep -Fqx 'APP_PORT=4567' "$GLOBAL_ENV" && grep -Fqx 'LEGACY=keep' "$GLOBAL_ENV" || fail "恢复历史文件丢失用户值"

setup manual
printf 'APP_PORT=3333\n# migrated from %s/a/deploy/.env\nAPP_PORT=4567\n' "$SOFTWARE_ROOT" > "$GLOBAL_ENV"
cp "$GLOBAL_ENV" "$tmp/before"
if run_env; then fail "未报告已编辑全局值与旧值冲突"; fi
cmp -s "$GLOBAL_ENV" "$tmp/before" || fail "冲突时改写了历史文件"

setup failure
printf 'SOFTWARE_ROOT=%s\nAPP_PORT=1234\nGITHUB_RUNNER_TOKEN=%s\n' "$SOFTWARE_ROOT" "$secret" > "$GLOBAL_ENV"
printf 'GITHUB_RUNNER_TOKEN=""\n' > "$GLOBAL_SECRETS"
cp "$GLOBAL_ENV" "$tmp/before"; cp "$GLOBAL_SECRETS" "$tmp/before-secret"
mkdir "$tmp/bin"
cat > "$tmp/bin/mv" <<'MOCK'
#!/usr/bin/env bash
[[ ${!#} != "$REJECT_TARGET" ]] || exit 73
exec /bin/mv "$@"
MOCK
chmod +x "$tmp/bin/mv"
if PATH="$tmp/bin:$PATH" REJECT_TARGET="$GLOBAL_SECRETS" run_env; then fail "目标写入失败被吞掉"; fi
cmp -s "$GLOBAL_ENV" "$tmp/before" && cmp -s "$GLOBAL_SECRETS" "$tmp/before-secret" || fail "目标写入失败时丢失原值"
if PATH="$tmp/bin:$PATH" REJECT_TARGET="$GLOBAL_ENV" run_env; then fail "来源替换失败被吞掉"; fi
cmp -s "$GLOBAL_ENV" "$tmp/before" || fail "来源替换失败时删除了原配置"
grep -Fqx "GITHUB_RUNNER_TOKEN=$secret" "$GLOBAL_SECRETS" || fail "清理来源之前没有确认目标落盘"
run_env || fail "故障后无法重试"
grep -Fqx "GITHUB_RUNNER_TOKEN=$secret" "$GLOBAL_SECRETS" || fail "重试丢失敏感值"
echo 'Linux/fnOS 配置迁移回归通过'
