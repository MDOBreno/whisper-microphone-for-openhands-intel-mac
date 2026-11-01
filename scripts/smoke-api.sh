#!/bin/bash
set -euo pipefail
URL="${WHISPER_API_URL:-http://127.0.0.1:8765/v1/audio/transcriptions}"
if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 audio-file" >&2
  exit 2
fi
response="$(mktemp)"
trap 'rm -f "$response"' EXIT
status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  -F "file=@$1" -F 'model=whisper-1' -F 'response_format=json' "$URL")"
[[ "$status" == 200 ]] || { cat "$response" >&2; echo "HTTP $status" >&2; exit 1; }
/usr/bin/python3 - "$response" <<'PY'
import json, sys
from pathlib import Path
body=json.loads(Path(sys.argv[1]).read_text())
text=body.get("text")
if not isinstance(text, str):
    raise SystemExit("Response JSON has no string 'text' field")
print(text)
PY
