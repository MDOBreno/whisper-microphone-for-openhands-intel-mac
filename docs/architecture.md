# Architecture

## Request path

1. OpenHands records through the Electron microphone permission and posts
   `multipart/form-data` to `http://127.0.0.1:8765/v1/audio/transcriptions`.
2. `src/openai_adapter.py` validates the request, converts browser formats with
   local FFmpeg when needed, and forwards inference to whisper.cpp on
   `127.0.0.1:8766`.
3. whisper.cpp runs multilingual Whisper inference. The OpenCL backend executes
   supported matrix operations on the selected AMD GPU; unsupported operations
   remain on the CPU.
4. The adapter returns OpenAI-compatible JSON, including `{"text":"..."}`.

Both HTTP listeners bind to loopback. No audio or transcription is sent to a
cloud API. The adapter limits uploads to 250 MiB, recording duration to 600 s,
and concurrent transcription to one request.

## AMD OpenCL compatibility

The tested Apple OpenCL runtime exposes OpenCL 1.2 and does not expose
`cl_khr_fp16` or subgroup operations. The patch adds subgroup-free tiled F32
matrix multiplication, software IEEE F16-to-F32 conversion, and Q8_0 weight
conversion/matmul support. This lets the RX 5600 run the multilingual Turbo
Q8_0 profile without falling back to CPU for its principal quantized matrix
multiplications. The fallback uses 16x16 tiles and splits large buffers into
chunks of at most 512 MiB to avoid a reproducible Apple AMD driver abort on
near-4-GiB allocations. Other unsupported operations may use existing CPU
backends. This is a hybrid backend, not a claim that every operation runs on
the GPU.

This project does not use Metal in its tested configuration. Earlier Metal
runs on this Intel Hackintosh caused GPU resets, so the working build uses the
AMD OpenCL device. Metal 3 is reported by the display driver but is not the
inference backend.

## GPU and model selection

At login, the daemon reads `system_profiler` and chooses the AMD OpenCL device
attached to the main display. It uses `sppci_model` (the human-readable model)
to match the OpenCL device. The internal `_name` token is not a valid OpenCL
device match string.

The daemon selects full multilingual Large V3 when the main GPU reports at
least 12 GiB VRAM, unquantized multilingual Turbo from 8 to 12 GiB, and
multilingual Turbo Q8_0 on GPUs up to 8 GiB. The current RX 5600 setup therefore
loads `ggml-large-v3-turbo-q8_0.bin` (873.55 MB on disk; 878.33 MB reported for
the OpenCL model allocation). The Q8_0 path keeps quantized weights in GPU
memory and computes the matrix product in F32. The RX 6900 XT setup selects full
Large V3.

On the RX 5600, an idle driver telemetry sample after inference reported
`inUseVidMemoryBytes` around 3.18 GiB, with about 2.72 GiB marked reusable by
the driver and around 85 MiB immediately free. These system-wide counters
include display allocations and driver caches; they do not guarantee a fixed
amount of free VRAM for other applications. GPU system-memory usage in that
sample was about 203 MiB. The inference model itself is GPU-resident and
OpenCL telemetry showed an active context and GPU activity during inference.

## OpenHands microphone permission

The installed OpenHands Agent Canvas 1.34.0 app is signed with an Apple
Development identity, has the
`com.apple.security.device.audio-input` entitlement, and has a macOS TCC
microphone grant. Its Voice Input fields point to the local adapter. Re-signing
the app is unnecessary unless a future app update replaces the current signed
bundle or revokes the permission. Never edit the signed app bundle without
re-signing it.

## LaunchAgent lifecycle

`local.whisper.openai` runs as a per-user GUI LaunchAgent with `RunAtLoad`,
`KeepAlive`, a 30-second throttle, and `ProcessType=Interactive`. It starts
after login so the display GPU is available. The supervisor starts the backend
and adapter, stops the sibling if either exits, and lets launchd restart the
service. The installer backs up the existing plist before replacing it. Before starting
the adapter, the supervisor verifies the backend startup log names both the
GPUOpenCL backend and requested AMD device; otherwise it exits so launchd can
retry instead of leaving an unnoticed CPU-only server running.
