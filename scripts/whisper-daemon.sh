#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ROOT="${WHISPER_RUNTIME_ROOT:-$PROJECT_ROOT}"
SERVER="${WHISPER_SERVER_PATH:-}"
if [[ -z "$SERVER" ]]; then
  for candidate in \
    "$PROJECT_ROOT/build/opencl120/bin/whisper-server" \
    "$PROJECT_ROOT/build-opencl120/bin/whisper-server" \
    "$RUNTIME_ROOT/build-opencl120/bin/whisper-server" \
    "$RUNTIME_ROOT/build/opencl120/bin/whisper-server"; do
    if [[ -x "$candidate" ]]; then SERVER="$candidate"; break; fi
  done
fi
LARGE_MODEL="$RUNTIME_ROOT/models/ggml-large-v3.bin"
TURBO_MODEL="$RUNTIME_ROOT/models/ggml-large-v3-turbo.bin"
TURBO_Q8_MODEL="$RUNTIME_ROOT/models/ggml-large-v3-turbo-q8_0.bin"

# This build has Metal disabled. The LaunchAgent runs after GUI login, when
# the interactive display GPU is available. Select the OpenCL device attached
# to the main display; an explicit GGML_OPENCL_DEVICE still overrides this for
# controlled tests (for example, selecting the secondary Vega by device index).
export GGML_OPENCL_PLATFORM="${GGML_OPENCL_PLATFORM:-0}"
gpu_info=$(
  /usr/sbin/system_profiler SPDisplaysDataType -json 2>/dev/null |
    /usr/bin/python3 -c 'import json,re,sys; data=json.load(sys.stdin); gpus=data.get("SPDisplaysDataType", []); g=next((g for g in gpus if any(d.get("spdisplays_main") == "spdisplays_yes" for d in g.get("spdisplays_ndrvs", []))), None); raw=(g or {}).get("spdisplays_vram", ""); m=re.search(r"([0-9.]+)\s*GB", raw, re.I); print("{}\t{}".format((g or {}).get("sppci_model") or (g or {}).get("_name", "AMD Radeon"), int(float(m.group(1))*1024**3) if m else 0))' \
    2>/dev/null || true
)
if [[ -z "$gpu_info" ]]; then gpu_info=$'AMD Radeon\t0'; fi
main_gpu="${gpu_info%%$'\t'*}"
gpu_vram_bytes="${gpu_info##*$'\t'}"
if ! [[ "$gpu_vram_bytes" =~ '^[0-9]+$' ]]; then gpu_vram_bytes=0; fi
if [[ -z "${GGML_OPENCL_DEVICE:-}" ]]; then
  export GGML_OPENCL_DEVICE="${main_gpu:-AMD Radeon}"
fi

# OpenCL computes in F32 using software conversion of F16 weights. Use the
# full multilingual Large V3 on GPUs with at least 12 GiB, unquantized Turbo
# from 8 to 12 GiB, and multilingual Turbo Q8_0 on cards up to 8 GiB to leave
# more VRAM available on cards such as the 6 GiB RX 5600.
if [[ -n "${WHISPER_MODEL_PATH:-}" ]]; then
  MODEL="$WHISPER_MODEL_PATH"
  model_name="${WHISPER_MODEL_NAME:-custom}"
elif (( gpu_vram_bytes >= 12884901888 )); then
  MODEL="$LARGE_MODEL"
  model_name="large-v3"
elif (( gpu_vram_bytes <= 8589934592 )); then
  MODEL="$TURBO_Q8_MODEL"
  model_name="large-v3-turbo-q8_0"
else
  MODEL="$TURBO_MODEL"
  model_name="large-v3-turbo"
fi
export WHISPER_MODEL_PATH="$MODEL"
export WHISPER_MODEL_NAME="${WHISPER_MODEL_NAME:-$model_name}"
export GGML_OPENCL_F32_BUFFER_MB="${GGML_OPENCL_F32_BUFFER_MB:-512}"
export WHISPER_BACKEND_URL="${WHISPER_BACKEND_URL:-http://127.0.0.1:8766/inference}"
export WHISPER_BACKEND_NAME="${WHISPER_BACKEND_NAME:-whisper.cpp/OpenCL $GGML_OPENCL_DEVICE (F32 compute; $WHISPER_MODEL_NAME)}"
unset GGML_METAL_DEVICE_NAME GGML_METAL_DEVICES GGML_METAL_CONCURRENCY_DISABLE

print -u2 "WhisperLocal GPU=$main_gpu VRAM=${gpu_vram_bytes}B OpenCL=$GGML_OPENCL_DEVICE model=$WHISPER_MODEL_NAME path=$MODEL"
if [[ ! -x "$SERVER" || ! -s "$MODEL" ]]; then
  print -u2 "WhisperLocal not ready: missing OpenCL server or model $MODEL"
  exit 78
fi

startup_log="$RUNTIME_ROOT/logs/service.err"
mkdir -p "$RUNTIME_ROOT/logs"
touch "$startup_log"
startup_log_line=$(wc -l < "$startup_log")
"$SERVER" --host 127.0.0.1 --port 8766 --model "$MODEL" --threads 8 --processors 1 \
  --language auto --suppress-nst --no-flash-attn &
backend_pid=$!
adapter_pid=""
cleanup() {
  if [[ -n "$adapter_pid" ]]; then
    kill "$adapter_pid" 2>/dev/null || true
    wait "$adapter_pid" 2>/dev/null || true
  fi
  kill "$backend_pid" 2>/dev/null || true
  wait "$backend_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for i in {1..120}; do
  if ! kill -0 "$backend_pid" 2>/dev/null; then
    wait "$backend_pid"
    exit $?
  fi
  if /usr/bin/curl -fsS http://127.0.0.1:8766/ >/dev/null 2>&1; then break; fi
  sleep 1
done
/usr/bin/curl -fsS http://127.0.0.1:8766/ >/dev/null || { print -u2 "whisper-server did not become ready"; exit 1; }
startup_lines=$(tail -n +$((startup_log_line + 1)) "$startup_log")
if ! print -r -- "$startup_lines" | /usr/bin/grep -Fq 'whisper_backend_init_gpu: using GPUOpenCL backend' ||
   ! print -r -- "$startup_lines" | /usr/bin/grep -Fq "ggml_opencl: OpenCL device: $GGML_OPENCL_DEVICE"; then
  print -u2 "Whisper GPU preflight failed: server did not initialize the requested AMD OpenCL device; refusing CPU-only fallback."
  exit 78
fi
/usr/bin/python3 "$PROJECT_ROOT/src/openai_adapter.py" &
adapter_pid=$!
while kill -0 "$backend_pid" 2>/dev/null && kill -0 "$adapter_pid" 2>/dev/null; do sleep 2; done
if ! kill -0 "$backend_pid" 2>/dev/null; then print -u2 "whisper-server PID $backend_pid exited unexpectedly."; fi
if ! kill -0 "$adapter_pid" 2>/dev/null; then print -u2 "OpenAI adapter PID $adapter_pid exited unexpectedly."; fi
print -u2 "WhisperLocal child exited unexpectedly; launchd will restart the service."
exit 1
