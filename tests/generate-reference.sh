#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$PROJECT_ROOT/tests/data"
mkdir -p "$OUT"
PT='Na conversa do OpenHands, vou pedir ao Claude Code para revisar o React app. O TypeScript compila, mas o backend Node.js está falhando na chamada da API. Depois faço commit no Git e confiro o workflow no GitHub Actions.'
EN='If the request fails, I will inspect the logs and fix the endpoint.'
say -v Luciana -r 175 -o "$OUT/pt.aiff" "$PT"
say -v Samantha -r 175 -o "$OUT/en.aiff" "$EN"
ffmpeg -nostdin -v error -y -i "$OUT/pt.aiff" -i "$OUT/en.aiff" \
  -filter_complex '[0:a]apad=pad_dur=0.4[a0];[a0][1:a]concat=n=2:v=0:a=1' \
  -ac 1 -ar 16000 -c:a pcm_s16le "$OUT/pt-en-mixed.wav"
echo "Generated synthetic test audio: $OUT/pt-en-mixed.wav"
