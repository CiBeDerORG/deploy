#!/usr/bin/env bash
# Canonical registry contract: tracked values win over user/env overrides.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
mkdir -p "$temp/deploy/lib"
cp "$repo/lib/versions.env" "$temp/deploy/lib/versions.env"
source "$repo/lib/versions.sh"
( 
  export EASYNETTOPO_IMAGE=easynettopo:obsolete
  export EASYHOSTAGENT_RELEASE=v9.9.9-obsolete
  deploy_load_versions "$temp"
  [[ "$EASYNETTOPO_IMAGE" = ghcr.io/cibederorg/easynettopo:main ]]
  [[ "$EASYHOSTAGENT_RELEASE" = v0.1.0-deploy-manifest-lifecycle.dev ]]
  [[ "$MIHOMO_NODE_VERSION" = v22.23.4 ]]
)
# Invalid content, unsupported keys, duplicate values and a missing file fail closed.
printf '%s\n' 'FRPS_IMAGE=invalid value' >> "$temp/deploy/lib/versions.env"
if (deploy_load_versions "$temp" > /dev/null 2>&1); then
  echo "非法镜像值被接受" >&2; exit 1
fi
cp "$repo/lib/versions.env" "$temp/deploy/lib/versions.env"
printf '%s\n' 'UNRECOGNIZED_IMAGE=evil:latest' >> "$temp/deploy/lib/versions.env"
if (deploy_load_versions "$temp" > /dev/null 2>&1); then
  echo "未知版本键被接受" >&2; exit 1
fi
cp "$repo/lib/versions.env" "$temp/deploy/lib/versions.env"
printf '%s\n' 'EASYNETTOPO_IMAGE=evil:latest' >> "$temp/deploy/lib/versions.env"
if (deploy_load_versions "$temp" > /dev/null 2>&1); then
  echo "重复镜像键被接受" >&2; exit 1
fi
rm "$temp/deploy/lib/versions.env"
if (deploy_load_versions "$temp" > /dev/null 2>&1); then
  echo "缺少版本文件被接受" >&2; exit 1
fi
echo "仓库版本唯一来源与安全校验通过"
