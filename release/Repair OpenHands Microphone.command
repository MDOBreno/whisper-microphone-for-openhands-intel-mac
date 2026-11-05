#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
exec "$SCRIPT_DIR/../scripts/openhands-microphone-repair.zsh" --update-and-repair
