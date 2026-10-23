#!/usr/bin/env bash
# Offline native adapter/launcher tests; HTTP checks bind loopback only.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "Native regression requires Node.js" >&2; exit 1; }
yaml_dir="${MIHOMO_TEST_YAML_DIR:-}"
if [ -z "$yaml_dir" ]; then
    yaml_dir="$(node -e 'const p=require("node:path");process.stdout.write(p.dirname(require.resolve("yaml/package.json", {paths:[process.argv[1]]})))' "$HERE")"
fi
[ -f "$yaml_dir/package.json" ] || { echo "Set MIHOMO_TEST_YAML_DIR to the installed upstream YAML package" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-host-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/release/launch" "$work/release/node_modules"
cp "$HERE/../deploy/host-kernel.sh" "$HERE/../deploy/host-config.mjs" \
   "$HERE/../deploy/host-health.mjs" "$work/release/launch/"
ln -s "$(cd -- "$yaml_dir" && pwd -P)" "$work/release/node_modules/yaml"
cp "$HERE/host-cases.mjs" "$work/release/host-cases.mjs"
node "$work/release/host-cases.mjs" "$HERE/../deploy"
echo "Native YAML, pinned launcher, legacy bridge and Web acceptance regression passed"
