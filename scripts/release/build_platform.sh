#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PLATFORM=${1:-}

if [[ -z "$PLATFORM" ]]; then
  case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux) PLATFORM="linux" ;;
    *)
      echo "Unsupported platform. Pass one of: macos, linux, windows" >&2
      exit 1
      ;;
  esac
fi

cd "$ROOT_DIR"

mix deps.get

if [[ "${BDS_SKIP_TESTS:-0}" != "1" ]]; then
  mix test
fi

MIX_ENV=prod mix release --overwrite bds
MIX_ENV=prod mix release --overwrite bds_mcp
MIX_ENV=prod mix bds.package "$PLATFORM"
