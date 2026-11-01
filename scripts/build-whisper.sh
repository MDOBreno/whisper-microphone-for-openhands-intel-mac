#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_SRC="$PROJECT_ROOT/third_party/whisper.cpp"
BUILD_DIR="$PROJECT_ROOT/build/opencl120"

if [[ ! -f "$WHISPER_SRC/CMakeLists.txt" ]]; then
  git -C "$PROJECT_ROOT" submodule update --init --recursive
fi
"$PROJECT_ROOT/scripts/apply-patches.sh"
cmake -S "$WHISPER_SRC" -B "$BUILD_DIR" \
  -DGGML_OPENCL=ON \
  -DGGML_OPENCL_TARGET_VERSION=120 \
  -DGGML_METAL=OFF \
  -DWHISPER_BUILD_SERVER=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64
cmake --build "$BUILD_DIR" --config Release --target whisper-server -j "${BUILD_JOBS:-8}"
echo "Built: $BUILD_DIR/bin/whisper-server"
