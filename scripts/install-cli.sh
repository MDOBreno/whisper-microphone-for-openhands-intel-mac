#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${WHISPER_CLI_DIR:-$HOME/.local/bin}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
mkdir -p "$DEST"
for action in status start stop restart logs; do
  ln -sfn "$PROJECT_ROOT/scripts/whisper-manage.zsh" "$DEST/whisper-$action"
done
python3 - "$ZSHRC" "$DEST" <<'PY'
from pathlib import Path
import shlex
import sys

zshrc = Path(sys.argv[1])
cli_dir = sys.argv[2]
marker = "# WhisperLocal CLI path (managed by whisper-microphone-for-openhands)"
contents = zshrc.read_text() if zshrc.exists() else ""
if marker not in contents:
    newline = chr(10)
    block = newline.join((
        marker,
        "typeset -U path PATH",
        f"path=({shlex.quote(cli_dir)} $path)",
    ))
    zshrc.parent.mkdir(parents=True, exist_ok=True)
    zshrc.write_text(contents.rstrip() + newline + newline + block + newline)
PY
printf 'Installed whisper CLI links in %s and added it to %s.\n' "$DEST" "$ZSHRC"
printf 'For this open terminal, run: source %s && rehash\n' "$ZSHRC"
