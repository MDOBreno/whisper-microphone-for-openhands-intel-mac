# Architecture

## Request path

1. OpenHands records through its Electron microphone permission and posts
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
`cl_khr_fp16` or subgroup operations. The patch adds tiled F32 matrix
multiplication and software IEEE F16-to-F32 conversion for F16 model weights.
The fallback uses 16x16 tiles and caps root buffers at 512 MiB to avoid a
reproducible Apple AMD driver abort on near-4-GiB allocations. Other operations
are left to existing backends/CPU. This build disables Metal because previous
Metal attempts caused GPU resets on the tested Intel Hackintosh.

## GPU and model selection

At login, the daemon reads `system_profiler` and chooses the AMD OpenCL device
attached to the main display. It selects the full multilingual Large V3 model
when that GPU reports at least 12 GiB VRAM; otherwise it selects the
multilingual Large V3 Turbo model. Both official model files use F16 weights,
without quantization. The OpenCL fallback computes in F32 and converts F16
weights in software.

The RX 6900 XT test used approximately 6.18 GB VRAM with Large V3 and 4.41 GB
with Turbo. The Turbo number projects to roughly 1.59 GB left on a nominal
6-GB RX 5600, but that RX 5600 profile still needs a direct measurement when the
card is installed. The fallback may allocate buffers in host memory if device
allocation fails; GPU matrix computation remains enabled, with potential speed
loss.

## LaunchAgent lifecycle

`local.whisper.openai` runs as a per-user GUI LaunchAgent with `RunAtLoad`,
`KeepAlive`, a 30-second throttle, and `ProcessType=Interactive`. It starts
after login so the display GPU is available. The supervisor starts the backend
and adapter, stops the sibling if either exits, and lets launchd restart the
service. The installer backs up the existing plist before replacing it.
