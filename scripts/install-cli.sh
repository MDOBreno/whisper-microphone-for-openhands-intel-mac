#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${WHISPER_CLI_DIR:-$HOME/.local/bin}"
mkdir -p "$DEST"
for action in status start stop restart logs; do
  ln -sfn "$PROJECT_ROOT/scripts/whisper-manage.zsh" "$DEST/whisper-$action"
done
printf 'Installed whisper CLI links in %s. Ensure that directory is on PATH.\n' "$DEST"
