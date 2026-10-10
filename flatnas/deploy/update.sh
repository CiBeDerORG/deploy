#!/usr/bin/env bash
set -Eeuo pipefail
DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DEPLOY_DIR/install.sh" update
