#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_SRC="$PROJECT_ROOT/third_party/whisper.cpp"
PATCH_FILE="$PROJECT_ROOT/patches/ggml-opencl-apple-1.2.patch"
EXPECTED_BASE="482279b8a18855ba741d7b88c30fcb3874691f59"

[[ -f "$WHISPER_SRC/CMakeLists.txt" ]] || {
  echo "whisper.cpp source is missing; run: git submodule update --init --recursive" >&2
  exit 1
}
if [[ -f "$WHISPER_SRC/.git" || -d "$WHISPER_SRC/.git" ]]; then
  actual_base="$(git -C "$WHISPER_SRC" rev-parse HEAD)"
  if [[ "$actual_base" != "$EXPECTED_BASE" ]]; then
    echo "Expected whisper.cpp $EXPECTED_BASE, found $actual_base." >&2
    echo "Review/rebase the OpenCL patch before building against another upstream revision." >&2
    exit 1
  fi
  git_args=(git -C "$WHISPER_SRC")
else
  # A packaged source archive has no Git metadata, but still carries the pinned source snapshot.
  cd "$WHISPER_SRC"
  git_args=(git)
fi
if "${git_args[@]}" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "OpenCL patch is already applied."
elif "${git_args[@]}" apply --check "$PATCH_FILE"; then
  "${git_args[@]}" apply "$PATCH_FILE"
  echo "Applied the Apple OpenCL 1.2 compatibility patch."
else
  echo "Patch does not apply cleanly to this whisper.cpp checkout." >&2
  exit 1
fi
