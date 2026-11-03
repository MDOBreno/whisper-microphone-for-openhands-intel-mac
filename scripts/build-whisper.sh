#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_SRC="$PROJECT_ROOT/third_party/whisper.cpp"
BUILD_DIR="$PROJECT_ROOT/build/opencl120"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
OPENCL_HEADERS="$SDK_PATH/System/Library/Frameworks/OpenCL.framework/Versions/A/Headers"
USER_ID="$(id -u)"
OPENCL_COMPAT_INCLUDE="/tmp/whisperlocal-opencl-compat-$USER_ID"

if [[ ! -f "$OPENCL_HEADERS/cl.h" ]]; then
  echo "Could not find the macOS OpenCL framework headers under $OPENCL_HEADERS." >&2
  exit 1
fi
mkdir -p "$OPENCL_COMPAT_INCLUDE"
ln -sfn "$OPENCL_HEADERS" "$OPENCL_COMPAT_INCLUDE/CL"
ln -sfn "$OPENCL_HEADERS" "$OPENCL_COMPAT_INCLUDE/OpenCL"

if [[ ! -f "$WHISPER_SRC/CMakeLists.txt" ]]; then
  git -C "$PROJECT_ROOT" submodule update --init --recursive
fi
"$PROJECT_ROOT/scripts/apply-patches.sh"
cmake -S "$WHISPER_SRC" -B "$BUILD_DIR" \
  -DGGML_OPENCL=ON \
  -DGGML_OPENCL_TARGET_VERSION=120 \
  -DGGML_OPENCL_USE_ADRENO_KERNELS=OFF \
  -DGGML_METAL=OFF \
  -DWHISPER_BUILD_SERVER=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS:-} -I$OPENCL_COMPAT_INCLUDE" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64
cmake --build "$BUILD_DIR" --config Release --target whisper-server -j "${BUILD_JOBS:-8}"
echo "Built: $BUILD_DIR/bin/whisper-server"
