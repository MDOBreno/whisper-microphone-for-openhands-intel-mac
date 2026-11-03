#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then echo "Usage: $0 VERSION (for example 0.1.0)" >&2; exit 2; fi
if ! git -C "$PROJECT_ROOT" diff --quiet || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
  echo "Commit or stash tracked changes before packaging a release." >&2; exit 1
fi
if [[ -n "$(git -C "$PROJECT_ROOT/third_party/whisper.cpp" status --porcelain)" ]]; then
  echo "The whisper.cpp submodule must be clean before packaging." >&2; exit 1
fi
mkdir -p "$PROJECT_ROOT/release"
archive="$PROJECT_ROOT/release/whisper-microphone-openhands-intel-mac-v$VERSION.tar.gz"
tmp="$archive.tmp"
rm -f "$tmp"
tar -czf "$tmp" \
  --exclude='./.git' \
  --exclude='./third_party/whisper.cpp/.git' \
  --exclude='./build/*' \
  --exclude='./release/*' \
  --exclude='./models/*' \
  --exclude='./logs/*' \
  --exclude='./tests/data/*' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  -C "$PROJECT_ROOT" .
mv "$tmp" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
printf 'Created %s and checksum.\n' "$archive"
