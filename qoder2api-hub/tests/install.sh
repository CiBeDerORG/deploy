#!/usr/bin/env bash
# Offline installer regression: mock Docker, exercise real GHCR round-robin.
set -Eeuo pipefail
[ "$(uname -s)" = Linux ] || { echo "Linux runner required"; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo "sudo required"; exit 1; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'sudo rm -rf -- "$tmp"' EXIT
# Keep CI diagnostics useful even for intentionally silent assertions.
TEST_PHASE=setup
trap 'rc=$?; printf "Qoder2API regression failed at line %s (%s, exit %s)\\n" "$LINENO" "$TEST_PHASE" "$rc" >&2' ERR
software="$tmp/software"
mkdir -p "$software/deploy/lib" "$software/qoder2api-hub/deploy" "$tmp/bin"
cp "$ROOT/lib/image-sources.sh" "$software/deploy/lib/image-sources.sh"
cp "$ROOT/lib/platform.sh" "$software/deploy/lib/platform.sh"
cp "$ROOT/qoder2api-hub/deploy/"*.sh "$ROOT/qoder2api-hub/deploy/docker-compose.yaml" "$software/qoder2api-hub/deploy/"
cat > "$software/deploy/.env" <<'EOF_ENV'
DOCKER_IMAGE_SOURCE=mirror
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
QODER2API_HUB_IMAGE=ghcr.io/shuishuipingan/qoder2api-hub:latest
QODER2API_HUB_BIND_IP=127.0.0.1
QODER2API_HUB_PORT=8790
EOF_ENV
cat > "$software/deploy/.secrets" <<'EOF_SECRETS'
QODER2API_HUB_API_KEY=
QODER2API_HUB_HTTP_PROXY=
QODER2API_HUB_HTTPS_PROXY=
QODER2API_HUB_ALL_PROXY=
EOF_SECRETS
cat > "$tmp/bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  info) exit 0 ;;
  compose)
    shift
    if [ "${1:-}" = version ]; then exit 0; fi
    while (($#)); do case "$1" in --project-directory|--env-file|-f) shift 2 ;; *) break ;; esac; done
    command="${1:-}"
    shift || true
    case "$command" in
      config) if [ "${1:-}" = --images ]; then printf '%s\n' "${DEPLOY_QODER2API_HUB_IMAGE:?missing routed image}"; fi; exit 0 ;;
      pull) printf 'pull:%s\n' "${DEPLOY_QODER2API_HUB_IMAGE:?}" >> "$MOCK_DOCKER_LOG" ;;
      up) : > "$MOCK_CONTAINER_STATE"; printf 'up:%s\n' "${DEPLOY_QODER2API_HUB_IMAGE:?}" >> "$MOCK_DOCKER_LOG" ;;
      ps) exit 0 ;;
      *) echo "Unexpected docker compose command: $command $*" >&2; exit 3 ;;
    esac ;;
  container) [ "${2:-}" = inspect ] && [ -f "$MOCK_CONTAINER_STATE" ] && exit 0; exit 1 ;;
  inspect) shift; [ "${1:-}" = --format ] && { echo qoder2api-hub; exit 0; }; exit 1 ;;
  *) echo "Unexpected docker command: $*" >&2; exit 3 ;;
esac
exit 0
EOF_DOCKER
chmod +x "$tmp/bin/docker"
touch "$tmp/docker.log" "$tmp/container-state"
chmod 0666 "$tmp/docker.log" "$tmp/container-state"
rm -f "$tmp/container-state"
TEST_PHASE=first-install
installer="$software/qoder2api-hub/deploy/install.sh"
sudo env PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker.log" MOCK_CONTAINER_STATE="$tmp/container-state" bash "$installer" install > "$tmp/install.log" 2>&1 || { cat "$tmp/install.log"; exit 1; }
TEST_PHASE=first-install-assertions
grep -q '镜像来源：加速站 dockerproxy' "$tmp/install.log"
grep -q 'ghcr.dockerproxy.net/shuishuipingan/qoder2api-hub:latest' "$tmp/install.log"
# The installer creates private root-owned state; verify directories without
# relaxing directory permissions just to satisfy a non-root CI runner.
sudo test -d "$software/qoder2api-hub/data/accounts"
sudo test -d "$software/qoder2api-hub/data/usage"
TEST_PHASE=update
sudo env PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker.log" MOCK_CONTAINER_STATE="$tmp/container-state" bash "$installer" update > "$tmp/update.log" 2>&1 || { cat "$tmp/update.log"; exit 1; }
TEST_PHASE=update-assertions
grep -q '镜像来源：加速站 ghproxy' "$tmp/update.log"
grep -q 'gh-proxy.com/docker/ghcr.io/shuishuipingan/qoder2api-hub:latest' "$tmp/update.log"
grep -Fx 'pull:ghcr.dockerproxy.net/shuishuipingan/qoder2api-hub:latest' "$tmp/docker.log" >/dev/null
grep -Fx 'pull:gh-proxy.com/docker/ghcr.io/shuishuipingan/qoder2api-hub:latest' "$tmp/docker.log" >/dev/null
test "$(grep -c '^pull:' "$tmp/docker.log")" -eq 2
! grep -Fq 'QODER2API_HUB_API_KEY=' "$tmp/install.log"
! grep -Fq 'QODER2API_HUB_API_KEY=' "$tmp/update.log"
echo "PASS: install/update preserve data, allow upstream-generated API key, and rotate GHCR mirrors"
