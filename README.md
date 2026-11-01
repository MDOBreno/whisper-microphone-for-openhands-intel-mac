# Whisper Microphone for OpenHands on Intel Mac

A local, OpenAI-compatible speech transcription service for OpenHands Agent Canvas on Intel Macs with AMD Radeon GPUs. It keeps audio on the Mac and runs multilingual Whisper through Apple's OpenCL 1.2 runtime. The repository includes a compatibility patch for the OpenCL capabilities exposed by the tested AMD driver, an HTTP adapter, LaunchAgent setup, build/download scripts, tests, and release packaging instructions.

## Highlights

- Brazilian Portuguese and English, with automatic language detection and mixed-language audio support.
- Multilingual Large V3 on a primary AMD GPU with at least 12 GiB VRAM; multilingual Large V3 Turbo below that threshold. Both official checkpoints use F16 weights without quantization.
- The OpenCL kernels compute in F32 and convert F16 weights in software, so the driver does not need `cl_khr_fp16`.
- OpenAI-compatible `POST /v1/audio/transcriptions` endpoint on loopback only.
- Local FFmpeg conversion for browser audio formats supported by the installed FFmpeg build.
- Per-user `launchd` service that starts after GUI login, keeps the model loaded, and recovers from a child-process failure.
- No cloud transcription API and no API usage charges.

## Tested host and measured behavior

The machine inspected for this implementation is an Intel Mac/Hackintosh running macOS 26.7 x86_64 with an Intel Core i9-10900K. The system enumerated an AMD Radeon RX 6900 XT with 16 GB VRAM as the main-display GPU and a secondary Radeon Vega. The RX 5600 was not physically installed during the final measurements.
On this host, the active LaunchAgent now runs the daemon and adapter from this Downloads checkout while reusing the compiled server and model files under `~/Applications/WhisperLocal`.

The Apple OpenCL runtime exposes OpenCL 1.2 without `cl_khr_fp16` or subgroup extensions. A tiled F32 matmul fallback and software F16-to-F32 weight conversion were added in `patches/ggml-opencl-apple-1.2.patch`. The build disables Metal: previous Metal attempts on this Hackintosh caused GPU resets. OpenCL inference completed with an active AMD OpenCL context, GPU activity observed up to 83%, and no reset in the recorded tests. Unsupported operations may still run on CPU; this is a hybrid backend, not a claim that every operation runs on GPU.

| Test | Observed result |
|---|---|
| Large V3 F16, mixed Portuguese/English reference audio, 21.86 s | HTTP 200 in 124.42 s; RTF 5.69; detected windows `pt, pt, pt, en`; preserved the speech order and most technical names. |
| Turbo F16, Portuguese audio, 10 s | HTTP 200 in 21.90 s; RTF 2.19; automatic language detection returned `pt`. |
| Large V3 F32, Portuguese WebM/Opus, 10 s | HTTP 200 in 41.32 s; local FFmpeg conversion succeeded. |
| Reference comparison on a short locally synthesized mixed-language script | Large V3 F16: WER 1.8%, CER 0.7%. Turbo checkpoint widened from the same F16 values to F32: WER 17.9%, CER 8.2%. This is a small synthetic `say` sample, not a human-spontaneous-speech benchmark. |
| GPU telemetry | RX 6900 XT OpenCL context active; up to 83% GPU activity. About 6.18 GB VRAM observed with Large V3 F16 and 4.41 GB with Turbo F16; process RSS was about 0.49 GB in one sample. |
| RX 5600 memory estimate | The Turbo test used about 4.41 GB on the RX 6900 XT. A simple 6 GB minus 4.41 GB estimate leaves about 1.59 GB on an RX 5600; this margin is narrow and must be measured with the RX 5600 installed. |
| LaunchAgent recovery | Deliberately terminated the adapter; launchd restarted the service, and one listener returned on each configured port. A full logout/reboot test was not performed. |

The full Large V3 profile is materially more accurate on the short reference test, so it is selected for the 16 GB RX 6900 XT. The smaller multilingual Turbo profile is selected for a 6 GB RX 5600 to leave VRAM available to other applications. Response time is hardware-bound and was not used as the selection gate.

## Repository layout

```text
.
├── config/                 # LaunchAgent template and optional audio entitlement
├── docs/                   # Architecture and runtime notes
├── build/opencl120/        # Local CMake output (ignored by Git)
├── logs/                   # Local service logs (ignored by Git)
├── models/                 # Downloaded model weights (ignored by Git)
├── patches/                # OpenCL 1.2 compatibility patch against pinned upstream
├── release/                # Release archives/checksums (ignored by Git)
├── scripts/                # Build, install, daemon, model, and release scripts
├── src/                    # OpenAI-compatible HTTP adapter
├── tests/                  # OpenCL smoke test and synthetic/API test helpers
└── third_party/whisper.cpp # Upstream whisper.cpp submodule, pinned to a known commit
```

Large Whisper checkpoints, compiled files, generated audio, logs, and release archives are not committed. The OpenAI adapter and service scripts are maintained here; the working machine can keep model/build assets in a separate runtime directory.

## Requirements

- Intel macOS with an AMD GPU and a logged-in GUI session.
- Xcode Command Line Tools, CMake, Git, Python 3, `curl`, and FFmpeg.
- Apple OpenCL framework (`/System/Library/Frameworks/OpenCL.framework`).
- A working AMD OpenCL device visible to `system_profiler` and OpenCL.
- Internet access only for cloning the public source submodule and downloading model weights. Inference itself is local.

On many Intel Macs, CMake and FFmpeg can be installed with Homebrew:

```zsh
brew install cmake ffmpeg
```

## Set up a fresh checkout

Clone with the pinned upstream submodule:

```zsh
git clone --recurse-submodules https://github.com/MDOBreno/whisper-microphone-for-openhands-intel-mac.git \
  "Whisper Microphone for OpenHands on Intel Mac"
cd "Whisper Microphone for OpenHands on Intel Mac"
```

Build the patched x86_64 OpenCL server and download the two multilingual models:

```zsh
./scripts/build-whisper.sh
./scripts/download-models.sh
```

The Large V3 checkpoint is several GB and the Turbo checkpoint is smaller. Do not commit files from `models/`.

Install the per-user LaunchAgent. By default, the project itself is used for models and build output:

```zsh
./scripts/install-launchagent.sh
./scripts/install-cli.sh
```

To keep build/model assets in a separate location, set `WHISPER_RUNTIME_ROOT` to that directory before installing. The runtime root must contain both model files and a built server under `build/opencl120/bin/` or `build-opencl120/bin/`.

## OpenHands settings

In OpenHands Agent Canvas, open **Settings → Application → Voice input** and use:

- **Transcription Base URL:** `http://127.0.0.1:8765/v1`
- **Transcription API Key:** leave blank
- **Transcription Model:** `whisper-1`

The OpenHands UI appends `/audio/transcriptions` to the base URL. Microphone capture still requires macOS microphone permission for the Electron app. The tested local installation has the `com.apple.security.device.audio-input` entitlement and a TCC microphone grant. The entitlement file here is an example for signing an app you own; this repository does not alter or re-sign OpenHands.

## API

```zsh
curl -F 'file=@audio.webm' \
  -F 'model=whisper-1' \
  -F 'response_format=json' \
  http://127.0.0.1:8765/v1/audio/transcriptions
```

The standard response is `{"text":"..."}`. Optional `language`, `prompt`, and `response_format` fields are accepted. Supported audio formats depend on local FFmpeg. The adapter allows uploads up to 250 MiB, audio up to 600 seconds, and one inference request at a time. It binds only to `127.0.0.1`; there is no authentication because it is not exposed to the LAN.

## Service commands and diagnostics

```zsh
whisper-status
whisper-start
whisper-stop
whisper-restart
whisper-logs
```

To inspect OpenCL selection and AMD telemetry:

```zsh
rg 'OpenCL|device|VRAM|model=' ~/Applications/WhisperLocal/logs/service.err
system_profiler SPDisplaysDataType
ioreg -r -d 1 -c IOAccelerator -l | rg 'contextCLCount|GPU Activity|inUseVidMemoryBytes|Temperature|Fan Speed'
```

`inUseVidMemoryBytes` is GPU memory/VRAM, not host RAM. OpenCL activity and an active context are evidence of GPU execution; host RSS alone does not show VRAM use.

## Development and validation

Apply the compatibility patch and build:

```zsh
./scripts/build-whisper.sh
```

Generate a short synthetic Portuguese/English reference recording (macOS `say` and FFmpeg required) and submit it to the local API:

```zsh
./tests/generate-reference.sh
./scripts/smoke-api.sh tests/data/pt-en-mixed.wav
```

The standalone OpenCL matrix-multiply smoke source is `tests/opencl_f32_smoke.cpp`. To inspect the installed API without transcribing audio:

```zsh
curl --fail http://127.0.0.1:8765/health
```

## Releasing

Before making a release, review model licensing/source attribution, test on the intended AMD GPU, and update the version/changelog. Commit all source changes, then package the repository and its pinned whisper.cpp source without model/build/log artifacts:

```zsh
git status --short
git tag -a v0.1.0 -m 'Whisper Microphone for OpenHands on Intel Mac v0.1.0'
./scripts/package-release.sh 0.1.0
```

The script writes a `.tar.gz` and SHA-256 file under `release/`. Upload the archive and checksum to the matching GitHub Release. Large model weights and compiled binaries are intentionally not included.

## Updating whisper.cpp

The patch is tied to commit `482279b8a18855ba741d7b88c30fcb3874691f59`. When updating the submodule, first review/rebase the patch and update the expected base revision in `scripts/apply-patches.sh`. Then rebuild, run the OpenCL/API checks, and remeasure VRAM before changing model-selection thresholds.

## Uninstall

Unload the LaunchAgent, then remove its plist and this checkout. This does not remove the separate runtime model directory unless you explicitly remove it:

```zsh
whisper-stop
rm "$HOME/Library/LaunchAgents/local.whisper.openai.plist"
rm -rf "$HOME/Downloads/Whisper Microphone for OpenHands on Intel Mac"
```
