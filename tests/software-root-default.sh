#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
grep -Fqx 'DEFAULT_SOFTWARE_ROOT="/opt/software"' deploy.sh
grep -Fqx 'LEGACY_LINUX_SOFTWARE_ROOT="/software"' deploy.sh
grep -Fqx 'FNOS_SOFTWARE_ROOT="/vol3/1000/software"' deploy.sh
grep -Fq 'SOFTWARE_ROOT=/opt/software' .env.example
grep -Fq 'elif [ -f "$DEFAULT_SOFTWARE_ROOT/deploy/.env" ]; then' deploy.sh
grep -Fq 'elif [ -f "$LEGACY_LINUX_SOFTWARE_ROOT/deploy/.env" ]; then' deploy.sh
grep -Fq 'set_software_root "$LEGACY_LINUX_SOFTWARE_ROOT"' deploy.sh
grep -Fq 'Ubuntu / 普通 Linux | `/opt/software`' README.md
echo "Software-root default and legacy compatibility checks passed."
