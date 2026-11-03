#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="${WHISPER_RUNTIME_ROOT:-$PROJECT_ROOT}"
LABEL="local.whisper.openai"
DOMAIN="gui/$(id -u)"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
TEMPLATE="$PROJECT_ROOT/config/local.whisper.openai.plist.in"

server="${WHISPER_SERVER_PATH:-}"
if [[ -z "$server" ]]; then
  for candidate in \
    "$PROJECT_ROOT/build/opencl120/bin/whisper-server" \
    "$PROJECT_ROOT/build-opencl120/bin/whisper-server" \
    "$RUNTIME_ROOT/build-opencl120/bin/whisper-server" \
    "$RUNTIME_ROOT/build/opencl120/bin/whisper-server"; do
    if [[ -x "$candidate" ]]; then server="$candidate"; break; fi
  done
fi
[[ -x "$server" ]] || { echo "whisper-server not found under $PROJECT_ROOT or $RUNTIME_ROOT; build it first." >&2; exit 1; }
[[ -s "$RUNTIME_ROOT/models/ggml-large-v3.bin" ]] || { echo "Missing Large V3 model under $RUNTIME_ROOT/models." >&2; exit 1; }
[[ -s "$RUNTIME_ROOT/models/ggml-large-v3-turbo.bin" ]] || { echo "Missing Large V3 Turbo model under $RUNTIME_ROOT/models." >&2; exit 1; }
[[ -s "$RUNTIME_ROOT/models/ggml-large-v3-turbo-q8_0.bin" ]] || { echo "Missing multilingual Large V3 Turbo Q8_0 model under $RUNTIME_ROOT/models." >&2; exit 1; }
mkdir -p "$AGENT_DIR" "$RUNTIME_ROOT/logs"

backup=""
if [[ -f "$PLIST" ]]; then
  backup="$PLIST.backup.$(date +%Y%m%d%H%M%S)"
  cp -p "$PLIST" "$backup"
fi
tmp_plist="$PLIST.tmp"
export PROJECT_ROOT RUNTIME_ROOT HOME LABEL
/usr/bin/python3 - "$TEMPLATE" "$tmp_plist" <<'PY'
import os, sys
from pathlib import Path
from xml.sax.saxutils import escape
template=Path(sys.argv[1]).read_text()
for key, value in {
    "@PROJECT_ROOT@": os.environ["PROJECT_ROOT"],
    "@RUNTIME_ROOT@": os.environ["RUNTIME_ROOT"],
    "@HOME@": os.environ["HOME"],
    "@LABEL@": os.environ["LABEL"],
}.items():
    template=template.replace(key, escape(value))
Path(sys.argv[2]).write_text(template)
PY
/usr/bin/plutil -lint "$tmp_plist"
mv "$tmp_plist" "$PLIST"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
  # launchd unregisters the old job asynchronously after terminating its process tree.
  for attempt in {1..30}; do
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then break; fi
    sleep 1
  done
fi
# Wait for the old adapter and backend sockets to close before loading their replacements.
for attempt in {1..60}; do
  api_busy=$(/usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null || true)
  backend_busy=$(/usr/sbin/lsof -nP -iTCP:8766 -sTCP:LISTEN 2>/dev/null || true)
  if [[ -z "$api_busy" && -z "$backend_busy" ]]; then break; fi
  sleep 1
done
if [[ -n "${api_busy:-}" || -n "${backend_busy:-}" ]]; then
  echo "Whisper listeners did not stop cleanly; refusing to launch a duplicate." >&2
  if [[ -n "$backup" ]]; then cp -p "$backup" "$PLIST"; fi
  exit 1
fi
bootstrapped=false
for attempt in {1..5}; do
  if launchctl bootstrap "$DOMAIN" "$PLIST"; then bootstrapped=true; break; fi
  sleep 2
done
if [[ "$bootstrapped" != true ]]; then
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then launchctl bootout "$DOMAIN/$LABEL" || true; fi
  if [[ -n "$backup" ]]; then
    cp -p "$backup" "$PLIST"
    for attempt in {1..5}; do
      if launchctl bootstrap "$DOMAIN" "$PLIST"; then break; fi
      sleep 2
    done
  fi
  exit 1
fi
printf 'Installed %s using code in %s and runtime assets in %s.\n' "$LABEL" "$PROJECT_ROOT" "$RUNTIME_ROOT"
