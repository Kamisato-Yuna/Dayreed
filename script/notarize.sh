#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Config is parsed as data by Python with owner/mode checks; never source a local file.
exec python3 "$ROOT_DIR/script/prepare_release.py" "$@"
