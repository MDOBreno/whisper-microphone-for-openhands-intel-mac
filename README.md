# Whisper Microphone for OpenHands on Intel Mac

A local, OpenAI-compatible speech transcription service for OpenHands Agent Canvas on Intel Macs with AMD Radeon GPUs. It keeps audio on the Mac and runs multilingual Whisper through Apple's OpenCL 1.2 runtime. The repository includes a compatibility patch for the OpenCL capabilities exposed by the tested AMD driver, an HTTP adapter, LaunchAgent setup, build/download scripts, tests, and release packaging instructions.

## Highlights

- Brazilian Portuguese and English, with automatic language detection and mixed-language audio support.
- Multilingual Large V3 on a primary AMD GPU with at least 12 GiB VRAM; full-precision Turbo from 8–12 GiB; multilingual Turbo Q8_0 on cards up to 8 GiB to preserve VRAM.
- The OpenCL kernels compute in F32 and convert F16 weights in software, so the driver does not need `cl_khr_fp16`.
- OpenAI-compatible `POST /v1/audio/transcriptions` endpoint on loopback only.
- Local FFmpeg conversion for browser audio formats supported by the installed FFmpeg build.
- Per-user `launchd` service that starts after GUI login, keeps the model loaded, recovers from child-process failure, and refuses CPU-only fallback when AMD OpenCL is unavailable.
- No cloud transcription API and no API usage charges.

## Tested host and measured behavior

The active test host inspected on 2026-11-03 is an Intel Mac/Hackintosh running macOS 26.7 (build 25G229), x86_64, Intel Core i7-10700, and 32 GB system RAM. Its main-display GPU is an AMD Radeon RX 5600 with 6 GB VRAM; a secondary AMD Radeon Vega is also present. The driver reports Metal 3, but this Whisper build deliberately uses Apple's OpenCL 1.2 runtime because earlier Metal runs on this Hackintosh caused GPU resets. The RX 5600 OpenCL tests below completed without a driver recovery. Do not describe this backend as Metal acceleration.

The Apple OpenCL runtime reports OpenCL 1.2 without `cl_khr_fp16` or subgroup operations. `patches/ggml-opencl-apple-1.2.patch` supplies tiled F32 matrix multiplication and software F16-to-F32 conversion; it also adds a Q8_0 GPU path so the small-card Turbo profile remains quantized in VRAM while multiplying in F32. Some unsupported operations remain on CPU. The daemon preflight requires logs to identify both `GPUOpenCL` and `AMD Radeon RX 5600 Compute Engine`, so an unsupported build exits instead of silently using CPU. A 19.96-second mixed test previously measured 82–89% GPU activity during inference with no GPU recovery.

The RX 5600 daemon selects the multilingual `large-v3-turbo-q8_0` model. Its OpenCL model allocation was 878.33 MB (model file 873.55 MB). This is GPU memory, not host RAM. In a later idle telemetry sample, `ioreg` reported 3.18 GiB total `inUseVidMemoryBytes`, around 2.72 GiB of that marked reusable by the AMD driver, about 87 MiB reported immediately free, and about 209 MiB in GPU system memory. These system-wide driver counters include display allocations and cached/reusable allocations; they do not establish a guaranteed 1.5 GiB of immediately free VRAM. Recheck them on a different display setup or while other GPU applications are open.

| Test on RX 5600 | Observed result |
|---|---|
| OpenCL F32 matrix smoke test | Passed on the AMD OpenCL device; maximum absolute error 0.0. |
| Portuguese, 10.00 s, `language` omitted | HTTP 200 in 41.57 s (RTF 4.16); automatic detection selected Portuguese. Output preserved the Portuguese language and accents; this is a short synthetic sample, not a human-speech accuracy score. |
| English, 10.00 s, `language` omitted | HTTP 200 in 41.90 s (RTF 4.19); automatic detection selected English. The short synthetic sample was mostly recognized; one technical word was rendered as “compatriot” instead of “compatible.” |
| OpenHands UI request, 17.76 s recorded audio | The configured app sent the request to the local endpoint and received HTTP 200 in 118.02 s. The test played synthetic speech into a headset output that the headset microphone could not capture, so this validates the app-to-API path only, not natural voice accuracy. |
| Earlier RX 6900 XT reference tests | Large V3 F16 was more accurate than Turbo F16 on a short synthesized mixed-language script (WER 1.8% vs. 17.9%; CER 0.7% vs. 8.2%). This was a small TTS sample, not a human-spontaneous-speech benchmark. The 16 GB RX 6900 XT profile remains full Large V3. |
| LaunchAgent recovery | A child-process failure was deliberately induced; launchd recovered the service and one listener returned on each configured port. The latest daemon also passed its AMD OpenCL preflight. RunAtLoad and KeepAlive are enabled. A fresh logout/reboot test was not performed. |

For the 6 GB RX 5600 the daemon uses Turbo Q8_0, while GPUs with at least 12 GiB use full Large V3 and 8–12 GiB GPUs use unquantized Turbo. This threshold is based on available VRAM and actual RX 5600 model-load/inference checks; it does not promise 1.5 GiB of immediately free VRAM under every display workload. The daemon matches the human-readable `sppci_model` value from `system_profiler` (for example, `AMD Radeon RX 5600`); `_name` is an internal token such as `kHW_AMDRadeonRX5600Item` and cannot be passed as an OpenCL device name.

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

Build the patched x86_64 OpenCL server and download the three multilingual model profiles:

```zsh
./scripts/build-whisper.sh
./scripts/download-models.sh
```

The Large V3 checkpoint is several GB, while the Turbo Q8_0 checkpoint is the small-card profile. Do not commit files from `models/`.

Install the per-user LaunchAgent. By default, the project itself is used for models and build output:

```zsh
./scripts/install-launchagent.sh
./scripts/install-cli.sh
```

The CLI installer adds its directory to interactive Zsh sessions. In a terminal that is already open, run `source ~/.zshrc && rehash` once, or open a new terminal.

To keep model and log assets in a separate location, set `WHISPER_RUNTIME_ROOT` to that directory before installing. The LaunchAgent uses a server built in this checkout first, then falls back to a server under the runtime root.

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
