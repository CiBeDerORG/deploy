#!/usr/bin/env bash
# Isolated installer lifecycle tests. No real root, network, Docker or systemd.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../deploy"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() { printf 'Host installer regression failed: %s\n' "$*" >&2; exit 1; }
assert_state() {
    [ "$(cat "$case_dir/state")" = "$1" ] || fail "unexpected service active state"
    [ "$(cat "$case_dir/enabled")" = "$2" ] || fail "unexpected service enable state"
}
fixture() {
    case_dir="$work/$1"
    module="$case_dir/software/mihomo"
    runtime="$module/runtime/host"
    deploy="$module/deploy"
    unit="$case_dir/systemd/deploy-mihomo.service"
    mkdir -p "$deploy" "$runtime/releases" "$case_dir/software/deploy" "$case_dir/systemd" \
        "$module/data/all-in-one/profiles"
    cp "$SOURCE/common.sh" "$SOURCE/migrate.sh" "$deploy/"
    printf 'MIHOMO_API_PORT=7012\nMIHOMO_CORE_API_PORT=7013\nMIHOMO_MIXED_PORT=7011\n' > "$case_dir/software/deploy/.env"
    printf 'MIHOMO_API_SECRET=fixture-api\nMIHOMO_CONTROL_TOKEN=fixture-control\n' > "$case_dir/software/deploy/.secrets"
    printf 'rules: []\n' > "$module/data/all-in-one/active.yaml"
    printf '[]\n' > "$module/data/all-in-one/profiles/index.json"
    cp "$module/data/all-in-one/active.yaml" "$case_dir/profile.before"
    printf 'inactive\n' > "$case_dir/state"
    printf 'disabled\n' > "$case_dir/enabled"
    : > "$case_dir/calls"
    cat > "$deploy/host-build.sh" <<'EOF_BUILD'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'build\n' >> "$MOCK_CASE/calls"
[ "${MOCK_BUILD_FAIL:-0}" = 0 ] || exit 31
out="$1"
mkdir -p "$out/server" "$out/ui-dist" "$MIHOMO_HOST_RUNTIME/node-fixture-new/bin"
printf '' > "$out/server/index.mjs"
printf '' > "$out/ui-dist/index.html"
printf '#!/bin/bash\nexit 0\n' > "$out/mihomo"
printf '#!/bin/bash\nexit 0\n' > "$MIHOMO_HOST_RUNTIME/node-fixture-new/bin/node"
chmod +x "$out/mihomo" "$MIHOMO_HOST_RUNTIME/node-fixture-new/bin/node"
ln -s ../../node-fixture-new "$out/node"
printf 'MetaCubeXD=v1.2.3\nMihomo=v1.2.3\nNode=fixture-new\n' > "$out/versions.txt"
[ "${MOCK_NEW_START_FAIL:-0}" = 0 ] || touch "$out/fail-start"
[ "${MOCK_NEW_HEALTH_FAIL:-0}" = 0 ] || touch "$out/fail-health"
EOF_BUILD
    cat > "$deploy/host-run.sh" <<'EOF_RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$#" -eq 0 ]; then
    module="$(cd -- "$(dirname -- "$0")/.." && pwd)"
    exec bash "$module/runtime/host/current/launch/host-run.sh" "$module"
fi
release="$(dirname -- "$(dirname -- "$(readlink -f "$0")")")"
printf 'start-new\n' >> "$MOCK_CASE/calls"
[ ! -e "$release/fail-start" ] || exit 42
EOF_RUN
    cat > "$deploy/host-legacy-run.sh" <<'EOF_LEGACY'
#!/usr/bin/env bash
printf 'start-legacy\n' >> "$MOCK_CASE/calls"
[ "${MOCK_ROLLBACK_FAIL:-0}" = 0 ] || exit 43
EOF_LEGACY
    printf '#!/bin/bash\n[ "${MOCK_PREFLIGHT_FAIL:-0}" = 0 ]\n' > "$deploy/host-kernel.sh"
    printf '// fixture transformer\n' > "$deploy/host-config.mjs"
    printf '// fixture health client\n' > "$deploy/host-health.mjs"
    cat > "$case_dir/driver.sh" <<'EOF_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$INSTALLER_UNDER_TEST"
export MOCK_CASE="$1"
MOCK_MODULE="$MOCK_CASE/software/mihomo"
MOCK_UNIT="$MOCK_CASE/systemd/deploy-mihomo.service"
host_system_unit_path() { printf '%s\n' "$MOCK_UNIT"; }
host_assert_platform() { :; }
id() { if [ "$1" = -u ]; then printf '0\n'; else command id "$@"; fi; }
chown() { :; }
docker() { return 1; }
host_wait_ready() {
    [ ! -f "$1/fail-health" ] && [ "$(cat "$MOCK_CASE/state")" = active ]
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$MOCK_CASE/calls"
    local operation="$1" value
    shift
    case "$operation" in
        show) [ ! -e "$MOCK_UNIT" ] || printf '%s\n' "$MOCK_UNIT" ;;
        is-active) [ "$(cat "$MOCK_CASE/state")" = active ] ;;
        is-enabled)
            value="$(cat "$MOCK_CASE/enabled")"
            printf '%s\n' "$value"
            [[ "$value" == enabled* ]]
            ;;
        stop) printf 'inactive\n' > "$MOCK_CASE/state" ;;
        daemon-reload) : ;;
        enable)
            if [ "$1" = --runtime ]; then value=enabled-runtime; else value=enabled; fi
            printf '%s\n' "$value" > "$MOCK_CASE/enabled"
            ;;
        disable)
            if [ "$1" = --runtime ]; then
                if [ "$(cat "$MOCK_CASE/enabled")" = enabled-runtime ]; then
                    printf 'disabled\n' > "$MOCK_CASE/enabled"
                fi
            else
                printf 'disabled\n' > "$MOCK_CASE/enabled"
                [ ! -L "$MOCK_UNIT" ] || rm -- "$MOCK_UNIT"
            fi
            ;;
        start)
            if grep -Fq "ExecStart=/bin/bash \"$MOCK_MODULE/deploy/host-run.sh\"" "$MOCK_UNIT"; then
                if ! bash "$MOCK_MODULE/deploy/host-run.sh"; then
                    printf 'inactive\n' > "$MOCK_CASE/state"; return 1
                fi
            elif ! bash "$MOCK_MODULE/runtime/host/current/launch/host-run.sh" "$MOCK_MODULE"; then
                printf 'inactive\n' > "$MOCK_CASE/state"; return 1
            fi
            printf 'active\n' > "$MOCK_CASE/state"
            ;;
        *) printf 'Unexpected mock systemctl operation\n' >&2; return 99 ;;
    esac
}
host_main "$2" "$MOCK_MODULE/deploy"
EOF_DRIVER
    export INSTALLER_UNDER_TEST="$SOURCE/host-install.sh"
    unset MOCK_BUILD_FAIL MOCK_NEW_START_FAIL MOCK_NEW_HEALTH_FAIL MOCK_ROLLBACK_FAIL MOCK_PREFLIGHT_FAIL
}
old_release() {
    local layout="$1" enabled="${2:-enabled}" registration="${3:-file}"
    mkdir -p "$runtime/releases/old/server" "$runtime/releases/old/ui-dist" "$runtime/node-fixture-old/bin"
    printf '' > "$runtime/releases/old/server/index.mjs"
    printf '' > "$runtime/releases/old/ui-dist/index.html"
    printf '#!/bin/bash\nexit 0\n' > "$runtime/releases/old/mihomo"
    printf '#!/bin/bash\nexit 0\n' > "$runtime/node-fixture-old/bin/node"
    chmod +x "$runtime/releases/old/mihomo" "$runtime/node-fixture-old/bin/node"
    ln -s releases/old "$runtime/current"
    ln -s node-fixture-old "$runtime/node-current"
    if [ "$layout" = versioned ]; then
        mkdir "$runtime/releases/old/launch"
        cp "$deploy/host-legacy-run.sh" "$runtime/releases/old/launch/host-run.sh"
        cp "$deploy/host-health.mjs" "$runtime/releases/old/launch/host-health.mjs"
        ln -s ../../node-fixture-old "$runtime/releases/old/node"
    fi
    printf '# Managed by CiBeDerORG/deploy Mihomo native installer\n[Service]\nExecStart=/bin/bash "%s/deploy/host-run.sh"\n' "$module" > "$unit"
    if [ "$registration" = link ]; then
        mkdir -p "$runtime/systemd"
        mv "$unit" "$runtime/systemd/deploy-mihomo.service"
        ln -s "$runtime/systemd/deploy-mihomo.service" "$unit"
        cp "$runtime/systemd/deploy-mihomo.service" "$case_dir/body.before"
    fi
    cp -a "$unit" "$case_dir/unit.before"
    printf 'active\n' > "$case_dir/state"
    printf '%s\n' "$enabled" > "$case_dir/enabled"
}
run_installer() {
    if bash "$case_dir/driver.sh" "$case_dir" "$1" > "$case_dir/run.log" 2>&1; then
        installer_rc=0
    else
        installer_rc=$?
    fi
    cmp -s "$module/data/all-in-one/active.yaml" "$case_dir/profile.before" || fail "shared profile was overwritten"
}
assert_old_restored() {
    [ "$installer_rc" -ne 0 ] || fail "expected installation failure"
    [ "$(readlink "$runtime/current")" = releases/old ] || fail "previous current was not restored"
    if [ -L "$case_dir/unit.before" ]; then
        [ -L "$unit" ] && [ "$(readlink "$unit")" = "$(readlink "$case_dir/unit.before")" ] || fail "previous unit link was not restored"
        cmp -s "$runtime/systemd/deploy-mihomo.service" "$case_dir/body.before" || fail "previous local unit body was not restored"
    else
        [ ! -L "$unit" ] && cmp -s "$unit" "$case_dir/unit.before" || fail "previous unit file was not restored"
    fi
    [ "$(readlink "$runtime/node-current")" = node-fixture-old ] || fail "legacy Node binding was changed"
}

fixture fresh-success
run_installer install
[ "$installer_rc" -eq 0 ] || fail "fresh installation failed"
assert_state active enabled
[ -f "$unit" ] && [ ! -L "$unit" ] || fail "late-mounted volume needs a real system registration file"
cmp -s "$unit" "$runtime/systemd/deploy-mihomo.service" || fail "module-local unit original differs from registration"
grep -Fxq "RequiresMountsFor=\"$module\"" "$unit" || fail "mount dependency is missing"
[ -f "$runtime/current/launch/host-config.mjs" ] && [ -f "$runtime/current/launch/host-health.mjs" ] || fail "release launch files missing"
[ "$(readlink "$runtime/current/node")" = ../../node-fixture-new ] || fail "release Node is not pinned"
[ ! -e "$runtime/node-current" ] || fail "new install uses mutable node-current"
grep -Fq "$runtime/logs/service.log" "$unit" || fail "service logs are outside module"
! grep -q 'RuntimeDirectory=' "$unit" || fail "unit still uses /run runtime directory"
first_release="$(readlink "$runtime/current")"
cp "$runtime/current/launch/host-run.sh" "$case_dir/first-launch.before"
printf '\n# Updated deploy wrapper fixture\n' >> "$deploy/host-run.sh"
run_installer update
[ "$installer_rc" -eq 0 ] || fail "updating an owned current-format registration failed"
assert_state active enabled
[ "$(readlink "$runtime/current")" != "$first_release" ] || fail "same-tag update overwrote an existing release"
cmp -s "$runtime/$first_release/launch/host-run.sh" "$case_dir/first-launch.before" || fail "repository sync changed the previous frozen launcher"
grep -q 'Updated deploy wrapper fixture' "$runtime/current/launch/host-run.sh" || fail "same-tag update did not snapshot the new launcher"

fixture build-failure
old_release versioned
export MOCK_BUILD_FAIL=1
run_installer update
assert_old_restored
assert_state active enabled
! grep -Eq '^systemctl (stop|start|enable|disable|daemon-reload)' "$case_dir/calls" || fail "build failure touched existing service"

fixture wrapper-rollback
old_release versioned
export MOCK_NEW_START_FAIL=1
run_installer update
assert_old_restored
assert_state active enabled
grep -qx start-legacy "$case_dir/calls" || fail "rollback did not use frozen previous wrapper"
grep -q '已恢复原来的宿主机服务状态' "$case_dir/run.log" || fail "rollback success not reported"

fixture linked-runtime-rollback
old_release versioned enabled-runtime link
export MOCK_NEW_HEALTH_FAIL=1
run_installer update
assert_old_restored
assert_state active enabled-runtime

fixture inactive-rollback
old_release versioned disabled
printf 'inactive\n' > "$case_dir/state"
export MOCK_NEW_START_FAIL=1
run_installer update
assert_old_restored
assert_state inactive disabled
! grep -qx start-legacy "$case_dir/calls" || fail "rollback started a previously inactive service"

fixture foreign-root
old_release versioned
printf '# Managed by CiBeDerORG/deploy Mihomo native installer\n[Service]\nExecStart=/bin/bash "/different-root/mihomo/deploy/host-run.sh"\n' > "$unit"
cp "$unit" "$case_dir/unit.before"
run_installer update
assert_old_restored
assert_state active enabled
! grep -qx build "$case_dir/calls" || fail "foreign service detected after building"
! grep -Eq '^systemctl (stop|start|enable|disable|daemon-reload)' "$case_dir/calls" || fail "foreign service was modified"

fixture legacy-first-upgrade
old_release legacy
export MOCK_NEW_START_FAIL=1
run_installer update
assert_old_restored
assert_state active enabled
[ -f "$runtime/releases/old/launch/host-run.sh" ] || fail "legacy release was not sealed"
[ "$(readlink "$runtime/releases/old/node")" = ../../node-fixture-old ] || fail "legacy rollback adopted a new Node"
grep -qx start-legacy "$case_dir/calls" || fail "legacy unit bridge could not start sealed old release"

fixture legacy-build-failure
old_release legacy
export MOCK_BUILD_FAIL=1
run_installer update
assert_old_restored
assert_state active enabled
[ -f "$runtime/releases/old/launch/host-run.sh" ] || fail "legacy bridge unavailable after build failure"

fixture failed-rollback
old_release versioned
export MOCK_NEW_START_FAIL=1 MOCK_ROLLBACK_FAIL=1
run_installer update
assert_old_restored
assert_state inactive enabled
grep -q '回退未完全成功' "$case_dir/run.log" || fail "rollback failure was hidden"
compgen -G "$runtime/.host-build.*/unit.previous" > /dev/null || fail "failed rollback discarded recovery backups"

fixture failed-first-install
export MOCK_NEW_START_FAIL=1
run_installer install
[ "$installer_rc" -ne 0 ] || fail "expected fresh startup failure"
assert_state inactive disabled
[ ! -e "$unit" ] && [ ! -L "$unit" ] || fail "failed first install left a registered unit"
[ ! -e "$runtime/current" ] && [ ! -L "$runtime/current" ] || fail "failed first install left current selected"
[ ! -e "$runtime/systemd/deploy-mihomo.service" ] || fail "failed first install left a unit body"
grep -q '已恢复原来的宿主机服务状态' "$case_dir/run.log" || fail "first-install rollback failed"

# The compatibility health mode must never weaken a new release's acceptance.
fixture health-mode
mkdir -p "$runtime/releases/check/node/bin" "$runtime/releases/check/launch"
cat > "$runtime/releases/check/node/bin/node" <<'EOF_HEALTH_NODE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HEALTH_ARGUMENTS_FILE"
EOF_HEALTH_NODE
chmod +x "$runtime/releases/check/node/bin/node"
(
    source "$SOURCE/host-install.sh"
    systemctl() { return 0; }
    SERVICE=fixture.service
    MIHOMO_API_BIND_IP=0.0.0.0 MIHOMO_CORE_API_BIND_IP=0.0.0.0
    MIHOMO_API_PORT=7012 MIHOMO_CORE_API_PORT=7013
    MIHOMO_CONTROL_TOKEN=fixture-control MIHOMO_API_SECRET=fixture-api
    export HEALTH_ARGUMENTS_FILE="$case_dir/health-arguments"
    host_wait_ready "$runtime/releases/check"
    ! grep -q -- '--service-only' "$HEALTH_ARGUMENTS_FILE" || fail "new release skipped full Web acceptance"
    touch "$runtime/releases/check/launch/legacy-layout"
    host_wait_ready "$runtime/releases/check"
    grep -qx -- '--service-only' "$HEALTH_ARGUMENTS_FILE" || fail "legacy rollback used the new release's Web gate"
)

fixture failed-pointer-rename
mkdir -p "$runtime/releases/old" "$runtime/releases/new"
ln -s releases/old "$runtime/current"
(
    source "$SOURCE/host-install.sh"
    RUNTIME="$runtime"
    fail_next_rename=1
    mv() {
        if (( fail_next_rename == 1 )); then fail_next_rename=0; return 1; fi
        command mv "$@"
    }
    if host_set_current releases/new; then fail "expected rename fault injection to fail"; fi
    host_set_current releases/old
    [ "$(readlink "$runtime/current")" = releases/old ] || fail "failed rename blocked restoring old pointer"
)

echo 'Native installer staging, frozen launchers, legacy migration, ownership and rollback regressions passed'
