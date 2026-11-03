#!/usr/bin/env bash
# Non-network installer regression: fake Docker, real shared GHCR image selector.
set -Eeuo pipefail
[ "$(uname -m)" = x86_64 ] || { echo 'Linux amd64 runner required'; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo 'sudo required'; exit 1; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'sudo rm -rf -- "$tmp"' EXIT
software="$tmp/software"
mkdir -p "$software/deploy/lib" "$software/easytier-automation-executor/deploy" "$tmp/bin"
cp "$ROOT/lib/image-sources.sh" "$software/deploy/lib/image-sources.sh"
cp "$ROOT/easytier-automation-executor/deploy/"*.sh "$ROOT/easytier-automation-executor/deploy/docker-compose.yaml" "$software/easytier-automation-executor/deploy/"
cat > "$software/deploy/.env" <<'EOF_ENV'
DOCKER_IMAGE_SOURCE=mirror
DOCKER_IMAGE_MIRRORS=dockerproxy,ghproxy
EASYTIER_EXECUTOR_IMAGE=ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center
EASYTIER_EXECUTOR_CALLBACK_URL=http://127.0.0.1:7007
EOF_ENV
printf 'EASYTIER_EXECUTOR_TOKEN=\nEASYTIER_EXECUTOR_TURN_SECRET=\n' > "$software/deploy/.secrets"
cat > "$tmp/bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  compose)
    shift
    if [ "${1:-}" = -f ]; then shift 2; fi
    case "${1:-}" in
      version) exit 0 ;;
      config)
        if [ "${2:-}" = --images ]; then
          printf '%s\n' "${DEPLOY_EASYTIER_EXECUTOR_IMAGE:?missing image routing}"
        fi
        exit 0 ;;
      pull) printf 'pull:%s\n' "${DEPLOY_EASYTIER_EXECUTOR_IMAGE:?}" >> "$MOCK_DOCKER_LOG" ;;
      up) printf 'up:%s\n' "${DEPLOY_EASYTIER_EXECUTOR_IMAGE:?}" >> "$MOCK_DOCKER_LOG" ;;
      ps) exit 0 ;;
      *) echo "Unexpected docker compose command: $*" >&2; exit 3 ;;
    esac ;;
  container) [ "${2:-}" = inspect ] && exit 1 ;;
  image) [ "${2:-}" = inspect ] && { echo amd64; exit 0; } ;;
  inspect) echo running ;;
  exec) exit 0 ;;
  *) echo "Unexpected docker command: $*" >&2; exit 3 ;;
esac
exit 0
EOF_DOCKER
chmod +x "$tmp/bin/docker"
touch "$tmp/docker.log"
chmod 0666 "$tmp/docker.log"
installer="$software/easytier-automation-executor/deploy/install.sh"
sudo env PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker.log" bash "$installer" update >"$tmp/update.log" 2>&1 || {
  cat "$tmp/update.log"; exit 1;
}
grep -q 'update 将按首次安装继续' "$tmp/update.log"
grep -q '镜像来源：加速站 dockerproxy' "$tmp/update.log"
grep -q '本次实际拉取镜像：ghcr.dockerproxy.net/cibederorg/easytier-automation-executor:feat-automation-center' "$tmp/update.log"
# The installer deliberately makes .secrets root:root 0600.
# Inspect as root in this non-root CI test; never relax production permissions.
sudo grep -Eq '^EASYTIER_EXECUTOR_TOKEN=[[:xdigit:]]{64}$' "$software/deploy/.secrets"
first_token="$(sudo grep '^EASYTIER_EXECUTOR_TOKEN=' "$software/deploy/.secrets")"
# Subsequent install uses the NEXT shared proxy, with the existing Token unchanged.
sudo env PATH="$tmp/bin:$PATH" MOCK_DOCKER_LOG="$tmp/docker.log" bash "$installer" install >"$tmp/install.log" 2>&1 || {
  cat "$tmp/install.log"; exit 1;
}
grep -q '镜像来源：加速站 ghproxy' "$tmp/install.log"
grep -q '本次实际拉取镜像：gh-proxy.com/docker/ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center' "$tmp/install.log"
test "$first_token" = "$(sudo grep '^EASYTIER_EXECUTOR_TOKEN=' "$software/deploy/.secrets")"
grep -Fx 'pull:ghcr.dockerproxy.net/cibederorg/easytier-automation-executor:feat-automation-center' "$tmp/docker.log" >/dev/null
grep -Fx 'pull:gh-proxy.com/docker/ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center' "$tmp/docker.log" >/dev/null
test "$(grep -c '^pull:' "$tmp/docker.log")" -eq 2
! grep -Fq "${first_token#*=}" "$tmp/update.log"
! grep -Fq "${first_token#*=}" "$tmp/install.log"
printf 'PASS: first update installs, install rotates GHCR mirror, Token persists and stays out of logs\n'
