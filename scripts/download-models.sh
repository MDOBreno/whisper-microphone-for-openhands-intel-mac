#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="${WHISPER_MODEL_DIR:-$PROJECT_ROOT/models}"
DOWNLOAD_SCRIPT="$PROJECT_ROOT/third_party/whisper.cpp/models/download-ggml-model.sh"
if [[ ! -x "$DOWNLOAD_SCRIPT" ]]; then
  git -C "$PROJECT_ROOT" submodule update --init --recursive
fi
mkdir -p "$MODEL_DIR"
"$DOWNLOAD_SCRIPT" large-v3 "$MODEL_DIR"
"$DOWNLOAD_SCRIPT" large-v3-turbo "$MODEL_DIR"
"$DOWNLOAD_SCRIPT" large-v3-turbo-q8_0 "$MODEL_DIR"
echo "Downloaded multilingual Large V3, Large V3 Turbo, and Q8_0 Turbo into $MODEL_DIR."
