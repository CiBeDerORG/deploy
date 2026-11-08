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
    echo "Uninstalled native Agent must not claim to be running" >&2
    exit 1
fi
grep -Eq 'macOS|LaunchAgent|目前只支持' "$RUNNER_TEMP/unsupported.out"

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
bash deploy.sh easynettopo update
bash deploy.sh easynettopo uninstall
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"

# The macOS installer must reuse Linux/fnOS GHCR routing for the entire
# config/pull/up operation; a choice is persisted only for a GHCR mirror install.
ENV_FILE="$SOFTWARE_ROOT/deploy/.env"
MIRROR_STATE="$SOFTWARE_ROOT/deploy/state/image-mirror.last"
ORIGIN_IMAGE="ghcr.io/cibederorg/easynettopo:feat-deploy-manifest-lifecycle"
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
assert_compose_image "ghcr.dockerproxy.net/cibederorg/easynettopo:feat-deploy-manifest-lifecycle"
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
echo "macOS deployment entry smoke checks passed"
