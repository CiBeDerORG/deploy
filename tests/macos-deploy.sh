#!/usr/bin/env bash
# 在 GitHub macos runner 上执行；不下载镜像，也不需要真实 Docker Engine。
set -euo pipefail
export SOFTWARE_ROOT="$RUNNER_TEMP/macos-deploy-fixture"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "测试只在 macOS 运行" >&2; exit 1; }
[[ "${BASH_VERSINFO[0]}" -eq 3 ]] || { echo "请在 macOS 自带 Bash 3.2 下运行" >&2; exit 1; }

bash -n deploy.sh macos/deploy.sh macos/compose-install.sh
bash deploy.sh list | grep -q 'easynettopo'
bash deploy.sh list | grep -q 'portainer'
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

if bash deploy.sh easyhostagent install >"$RUNNER_TEMP/unsupported.out" 2>&1; then
    echo "Linux-only Agent must fail closed" >&2
    exit 1
fi
grep -q '暂未适配 macOS' "$RUNNER_TEMP/unsupported.out"

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
  compose)
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
bash deploy.sh easynettopo install
grep -Eq '^EASYNETTOPO_ADMIN_PASSWORD=[a-f0-9]{48}$' "$SOFTWARE_ROOT/deploy/.secrets"
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"

touch "$SOFTWARE_ROOT/easynettopo/data/app.db"
bash deploy.sh easynettopo update
bash deploy.sh easynettopo uninstall
grep -Fxq 'KEEP-ME' "$SOFTWARE_ROOT/easynettopo/data/sentinel"
echo "macOS deployment entry smoke checks passed"
