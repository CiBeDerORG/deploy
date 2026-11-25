#!/usr/bin/env bash
# 在 GitHub macos runner 上执行；不下载镜像，也不需要真实 Docker Engine。
set -euo pipefail
# 保证后续 bash 命令使用 macOS 系统自带的 Bash 3.2。
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export SOFTWARE_ROOT="$RUNNER_TEMP/macos-deploy-fixture"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "测试只在 macOS 运行" >&2; exit 1; }
[[ "${BASH_VERSINFO[0]}" -eq 3 ]] || { echo "请在 macOS 自带 Bash 3.2 下运行" >&2; exit 1; }

bash -n deploy.sh macos/deploy.sh macos/compose-install.sh macos/agent-install.sh
LIST_OUTPUT="$(bash deploy.sh list)"
grep -q 'easynettopo' <<< "$LIST_OUTPUT"
grep -q 'portainer' <<< "$LIST_OUTPUT"
grep -Fq 'maestro' <<< "$LIST_OUTPUT"
grep -Fq 'maestro' <<< "$(bash deploy.sh --help)"
bash deploy.sh env
[[ -f "$SOFTWARE_ROOT/deploy/.env" && -f "$SOFTWARE_ROOT/deploy/.secrets" ]]
[[ "$(stat -f '%Lp' "$SOFTWARE_ROOT/deploy/.env")" == 600 ]]
[[ "$(stat -f '%Lp' "$SOFTWARE_ROOT/deploy/.secrets")" == 600 ]]
grep -Fxq "SOFTWARE_ROOT=$SOFTWARE_ROOT" "$SOFTWARE_ROOT/deploy/.env"

printf '\n# preserved setting\n' >> "$SOFTWARE_ROOT/deploy/.env"
bash deploy.sh env
grep -Fxq '# preserved setting' "$SOFTWARE_ROOT/deploy/.env"

bash deploy.sh easynettopo sync
[[ -f "$SOFTWARE_ROOT/easynettopo/deploy/docker-compose.yaml" ]]
[[ -f "$SOFTWARE_ROOT/easynettopo/deploy/docker-compose.macos.yaml" ]]
mkdir -p "$SOFTWARE_ROOT/easynettopo/data"
printf 'KEEP-ME\n' > "$SOFTWARE_ROOT/easynettopo/data/sentinel"
bash deploy.sh easynettopo sync
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"

# 尚未安装的 Agent 查询应失败，但必须进入 macOS 专用路径，不能调用 Linux systemd。
if bash deploy.sh easyhostagent status >"$RUNNER_TEMP/unsupported.out" 2>&1; then
    echo "未安装 Agent 时，状态查询应返回失败" >&2
    exit 1
fi
grep -Fq 'Agent 尚未由当前安装器安装' "$RUNNER_TEMP/unsupported.out"

# Docker stub exercises the same installation path without publishing or running containers.
# Real Docker Desktop integration and actual volume-write permissions remain separate acceptance criteria.
FAKE_BIN="$RUNNER_TEMP/mock-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
case "$1" in
  info) exit 0 ;;
  ps) exit 0 ;;
  container) exit 1 ;;
  image) exit 0 ;;
  compose)
    # Capture the effective image used by each Compose operation without logging secrets.
    printf '%s|%s\n' "$*" "${DEPLOY_EASYNETTOPO_IMAGE:-}" >> "$MOCK_DOCKER_LOG"
    hook_token="${EASYNETTOPO_HOOK_TOKEN:-}"
    printf 'hook-token-length=%s\n' "${#hook_token}" >> "$MOCK_DOCKER_LOG"
    case " $* " in
      *" version "*) echo 'Docker Compose version v2.mock'; exit 0 ;;
      *" exec -T easynettopo wget "*) printf '{"initialized":false}\n'; exit 0 ;;
      *" exec -T easynettopo /usr/local/bin/easynettopo admin init --stdin "*)
        cat >/dev/null; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) printf 'unexpected docker command: %s\n' "$*" >&2; exit 2 ;;
esac
DOCKER
chmod +x "$FAKE_BIN/docker"
export PATH="$FAKE_BIN:$PATH"
export MOCK_DOCKER_LOG="$RUNNER_TEMP/mock-docker-images.log"
: > "$MOCK_DOCKER_LOG"
bash deploy.sh easynettopo install
grep -Eq '^EASYNETTOPO_ADMIN_PASSWORD=[a-f0-9]{48}$' "$SOFTWARE_ROOT/deploy/.secrets"
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"

touch "$SOFTWARE_ROOT/easynettopo/data/app.db"
# 在 macOS 更新时从全局 .secrets 注入 Hook Token，不在构建/测试日志中打印密钥。
sed -i '' 's/^EASYNETTOPO_HOOK_TOKEN=.*/EASYNETTOPO_HOOK_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/' "$SOFTWARE_ROOT/deploy/.secrets"
: > "$MOCK_DOCKER_LOG"
bash deploy.sh easynettopo update
grep -Fxq 'hook-token-length=64' "$MOCK_DOCKER_LOG"
bash deploy.sh easynettopo uninstall
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"

# The macOS installer must reuse Linux/fnOS GHCR routing for the entire
# config/pull/up operation; a choice is persisted only for a GHCR mirror install.
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
MIRROR_STATE="$SOFTWARE_ROOT/deploy/state/image-mirror.last"
ORIGIN_IMAGE="ghcr.io/cibederorg/easynettopo:main"
[[ ! -e "$MIRROR_STATE" ]] || { echo "original mode advanced mirror rotation" >&2; exit 1; }
assert_compose_image() {
    local expected="$1"
    grep -Fq " config --quiet|$expected" "$MOCK_DOCKER_LOG"
    grep -Fq " pull|$expected" "$MOCK_DOCKER_LOG"
    grep -Fq " up -d --remove-orphans --pull never --wait --wait-timeout 180|$expected" "$MOCK_DOCKER_LOG"
}
sed -i '' 's/^DOCKER_IMAGE_SOURCE=.*/DOCKER_IMAGE_SOURCE=mirror/' "$ENV_FILE"
: > "$MOCK_DOCKER_LOG"
bash deploy.sh easynettopo install
[[ "$(cat "$MIRROR_STATE")" == dockerproxy ]]
assert_compose_image "ghcr.dockerproxy.net/cibederorg/easynettopo:main"
: > "$MOCK_DOCKER_LOG"
bash deploy.sh easynettopo update
[[ "$(cat "$MIRROR_STATE")" == ghproxy ]]
assert_compose_image "gh-proxy.com/docker/$ORIGIN_IMAGE"

# A stale user .env IMAGE override must never change the repository version.
# Switch to original to confirm no mirror source is selected or rotated.
printf 'EASYNETTOPO_IMAGE=easynettopo:local\n' >> "$ENV_FILE"
sed -i '' 's/^DOCKER_IMAGE_SOURCE=.*/DOCKER_IMAGE_SOURCE=original/' "$ENV_FILE"
: > "$MOCK_DOCKER_LOG"
bash deploy.sh easynettopo update
[[ "$(cat "$MIRROR_STATE")" == ghproxy ]]
assert_compose_image "$ORIGIN_IMAGE"
# Legacy override is ignored even if it has a valid local tag.
[[ -f "$SOFTWARE_ROOT/deploy/lib/versions.env" ]]
grep -Fxq "EASYNETTOPO_IMAGE=$ORIGIN_IMAGE" "$SOFTWARE_ROOT/deploy/lib/versions.env"

# Invalid mirror list fails before Compose pull, preserving the last state.
sed -i '' 's/^DOCKER_IMAGE_SOURCE=.*/DOCKER_IMAGE_SOURCE=mirror/' "$ENV_FILE"
sed -i '' 's/^DOCKER_IMAGE_MIRRORS=.*/DOCKER_IMAGE_MIRRORS=unknown-provider/' "$ENV_FILE"
: > "$MOCK_DOCKER_LOG"
if bash deploy.sh easynettopo update >"$RUNNER_TEMP/invalid-mirror.out" 2>&1; then
    echo "invalid mirror provider was unexpectedly accepted" >&2
    exit 1
fi
grep -Fq "DOCKER_IMAGE_MIRRORS" "$RUNNER_TEMP/invalid-mirror.out"
[[ "$(cat "$MIRROR_STATE")" == ghproxy ]]
if grep -Fq " pull|" "$MOCK_DOCKER_LOG"; then
    echo "invalid mirror config reached compose pull" >&2
    exit 1
fi

# Uninstall remains offline and must not rotate a mirror, even with invalid settings.
bash deploy.sh easynettopo uninstall
[[ "$(cat "$MIRROR_STATE")" == ghproxy ]]
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"

# 在独立前缀内模拟 Homebrew，防止测试读到 Runner 预装的 SDK 或修改真实软件。
(
    export MAESTRO_FIXTURE="$RUNNER_TEMP/maestro-fixture"
    prefix="$MAESTRO_FIXTURE/brew"
    fixture_bin="$MAESTRO_FIXTURE/bin"
    fixture_home="$MAESTRO_FIXTURE/home"
    export SOFTWARE_ROOT="$MAESTRO_FIXTURE/未使用的 deploy 目录"
    export PATH="$fixture_bin:/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$fixture_bin" "$prefix/bin" "$fixture_home/.maestro"
    printf '用户流程\n' > "$fixture_home/.maestro/flow.yaml"
    cat > "$fixture_bin/brew" <<'BREW'
#!/bin/bash
set -eu
prefix="$MAESTRO_FIXTURE/brew"
printf '%s\n' "$*" >> "$MAESTRO_FIXTURE/brew.log"
[[ "$*" != "${MOCK_BREW_FAILURE:-}" ]] || exit 17
case "$*" in
    '--prefix') echo "$prefix" ;;
    '--prefix openjdk') echo "$prefix/opt/openjdk" ;;
    'list --formula --full-name')
        echo 'unrelated-tool'
        if [[ -n "${MOCK_OTHER_MAESTRO:-}" ]]; then echo 'other/tap/maestro'; fi
        if [[ -x "$prefix/bin/maestro" ]]; then echo 'mobile-dev-inc/tap/maestro'; fi ;;
    'install --cask android-platform-tools') cp "$MAESTRO_FIXTURE/adb" "$prefix/bin/adb" ;;
    'install --formula mobile-dev-inc/tap/maestro') cp "$MAESTRO_FIXTURE/maestro" "$prefix/bin/maestro" ;;
    'upgrade --formula mobile-dev-inc/tap/maestro') [[ -x "$prefix/bin/maestro" ]] ;;
    'uninstall --formula mobile-dev-inc/tap/maestro')
        [[ "${HOMEBREW_NO_AUTOREMOVE:-}" == 1 ]]
        rm "$prefix/bin/maestro" ;;
    *) echo "意外的 Homebrew 调用：$*" >&2; exit 2 ;;
esac
BREW
    cat > "$MAESTRO_FIXTURE/maestro" <<'MAESTRO'
#!/bin/bash
set -eu
[[ "$*" == "--version" ]]
[[ "$JAVA_HOME" == "$MAESTRO_FIXTURE/brew/opt/openjdk/libexec/openjdk.jdk/Contents/Home" ]]
echo "$*" >> "$MAESTRO_FIXTURE/maestro.log"
echo 'Maestro 测试版本'
MAESTRO
    cat > "$MAESTRO_FIXTURE/adb" <<'ADB'
#!/bin/bash
set -eu
[[ "$*" == "version" ]]
echo "$0" >> "$MAESTRO_FIXTURE/adb.log"
echo 'Android Debug Bridge 测试版本'
ADB
    cat > "$fixture_bin/docker" <<'NO_DOCKER'
#!/bin/bash
touch "$MAESTRO_FIXTURE/docker-called"
exit 1
NO_DOCKER
    chmod +x "$fixture_bin/brew" "$fixture_bin/docker" "$MAESTRO_FIXTURE/adb" "$MAESTRO_FIXTURE/maestro"
    run_maestro() { env HOME="$fixture_home" /bin/bash deploy.sh maestro "$@"; }

    if MOCK_OTHER_MAESTRO=1 run_maestro install; then
        echo '安装应拒绝接管其他 tap 的同名公式' >&2; exit 1
    fi
    MOCK_OTHER_MAESTRO=1 run_maestro uninstall
    if grep -Eq '^(install|upgrade|uninstall) ' "$MAESTRO_FIXTURE/brew.log"; then
        echo '其他来源的同名公式被修改' >&2; exit 1
    fi

    # 已有 SDK 优先使用 PATH 中的 adb；公式安装失败后可重试，重复安装不得升级。
    cp "$MAESTRO_FIXTURE/adb" "$fixture_bin/adb"
    if MOCK_BREW_FAILURE='install --formula mobile-dev-inc/tap/maestro' run_maestro install; then
        echo 'Maestro 安装应传递 Homebrew 失败' >&2; exit 1
    fi
    : > "$MAESTRO_FIXTURE/brew.log"
    run_maestro install
    run_maestro install
    [[ "$(grep -c '^install --formula ' "$MAESTRO_FIXTURE/brew.log")" == 1 ]]
    if grep -Eq '^(install --cask|upgrade) ' "$MAESTRO_FIXTURE/brew.log"; then
        echo '重复安装误触发了升级或替换已有 ADB' >&2; exit 1
    fi
    grep -Fxq "$fixture_bin/adb" "$MAESTRO_FIXTURE/adb.log"
    grep -Fxq -- '--version' "$MAESTRO_FIXTURE/maestro.log"
    run_maestro update
    grep -Fxq 'upgrade --formula mobile-dev-inc/tap/maestro' "$MAESTRO_FIXTURE/brew.log"
    run_maestro uninstall
    [[ -x "$fixture_bin/adb" && ! -e "$prefix/bin/maestro" ]]

    # 未安装时 update 补装公式；补装 ADB 失败后可安全重试。
    rm "$fixture_bin/adb"
    : > "$MAESTRO_FIXTURE/brew.log"
    if MOCK_BREW_FAILURE='install --cask android-platform-tools' run_maestro update; then
        echo 'Maestro 首次更新应传递 ADB 安装失败' >&2; exit 1
    fi
    [[ ! -e "$prefix/bin/adb" && -x "$prefix/bin/maestro" ]]
    run_maestro update
    [[ "$(grep -Fc 'install --cask android-platform-tools' "$MAESTRO_FIXTURE/brew.log")" == 2 ]]
    [[ "$(grep -c '^install --formula ' "$MAESTRO_FIXTURE/brew.log")" == 1 ]]
    grep -Fxq "$prefix/bin/adb" "$MAESTRO_FIXTURE/adb.log"
    run_maestro uninstall
    run_maestro uninstall
    [[ -x "$prefix/bin/adb" && ! -e "$prefix/bin/maestro" ]]
    [[ "$(grep -c '^uninstall ' "$MAESTRO_FIXTURE/brew.log")" == 1 ]]

    # Linux 通过 */deploy/install.sh 发现应用；这里同时核对该入口及 Linux 帮助。
    cat > "$fixture_bin/uname" <<'LINUX'
#!/bin/bash
[[ "$*" == "-s" ]] && { echo Linux; exit 0; }
exec /usr/bin/uname "$@"
LINUX
    chmod +x "$fixture_bin/uname"
    : > "$MAESTRO_FIXTURE/brew.log"
    linux_help="$(env HOME="$fixture_home" /bin/bash deploy.sh --help)"
    if grep -Fq 'maestro' <<< "$linux_help" || [[ -e maestro/deploy/install.sh ]]; then
        echo 'Linux 入口误暴露了 macOS 专用的 Maestro 安装能力' >&2; exit 1
    fi
    [[ ! -s "$MAESTRO_FIXTURE/brew.log" && ! -e "$MAESTRO_FIXTURE/docker-called" ]]
    grep -Fxq '用户流程' "$fixture_home/.maestro/flow.yaml"
    [[ ! -e "$SOFTWARE_ROOT" ]]
)
echo "macOS 部署入口冒烟检查通过"
