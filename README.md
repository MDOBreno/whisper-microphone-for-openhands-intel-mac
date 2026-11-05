# Whisper Microphone for OpenHands on Intel Mac

A local, OpenAI-compatible speech transcription service for OpenHands Agent Canvas on Intel Macs with AMD Radeon GPUs. It keeps audio on the Mac and runs multilingual Whisper through Apple's OpenCL 1.2 runtime. The repository includes a compatibility patch for the OpenCL capabilities exposed by the tested AMD driver, an HTTP adapter, LaunchAgent setup, build/download scripts, tests, and release packaging instructions.

## Highlights

- Brazilian Portuguese and English, with automatic language detection and mixed-language audio support.
- Multilingual Large V3 on a primary AMD GPU with at least 12 GiB VRAM; full-precision Turbo from 8–12 GiB; multilingual Turbo Q8_0 on cards up to 8 GiB to preserve VRAM.
- The OpenCL kernels compute in F32 and convert F16 weights in software, so the driver does not need `cl_khr_fp16`.
- OpenAI-compatible `POST /v1/audio/transcriptions` endpoint on loopback only.
- Local FFmpeg conversion for browser audio formats supported by the installed FFmpeg build.
- Per-user `launchd` service that starts after GUI login, keeps the model loaded, recovers from child-process failure, and refuses CPU-only fallback when AMD OpenCL is unavailable.
- Runtime GPU selection limited to the supported RX 6900 XT and RX 5600; the integrated Vega's shared memory is not mistaken for dedicated VRAM.
- No cloud transcription API and no API usage charges.

## Tested host and measured behavior

The active test host inspected on 2026-11-03 is an Intel Mac/Hackintosh running macOS 26.7 (build 25G229), x86_64, Intel Core i7-10700, and 32 GB system RAM. Its main-display GPU is an AMD Radeon RX 5600 with 6 GB VRAM; a secondary AMD Radeon Vega is also present. The driver reports Metal 3, but this Whisper build deliberately uses Apple's OpenCL 1.2 runtime because earlier Metal runs on this Hackintosh caused GPU resets. The RX 5600 OpenCL tests below completed without a driver recovery. Do not describe this backend as Metal acceleration.

The Apple OpenCL runtime reports OpenCL 1.2 without `cl_khr_fp16` or subgroup operations. `patches/ggml-opencl-apple-1.2.patch` supplies tiled F32 matrix multiplication and software F16-to-F32 conversion; it also adds a Q8_0 GPU path so the small-card Turbo profile remains quantized in VRAM while multiplying in F32. Some unsupported operations remain on CPU. The daemon preflight requires logs to identify both `GPUOpenCL` and `AMD Radeon RX 5600 Compute Engine`, so an unsupported build exits instead of silently using CPU. A 19.96-second mixed test previously measured 82–89% GPU activity during inference with no GPU recovery.

The RX 5600 daemon selects the multilingual `large-v3-turbo-q8_0` model. Its OpenCL model allocation was 878.33 MB (model file 873.55 MB). This is GPU memory, not host RAM. In a later idle telemetry sample, `ioreg` reported 3.18 GiB total `inUseVidMemoryBytes`, around 2.72 GiB of that marked reusable by the AMD driver, about 87 MiB reported immediately free, and about 209 MiB in GPU system memory. These system-wide driver counters include display allocations and cached/reusable allocations; they do not establish a guaranteed 1.5 GiB of immediately free VRAM. Recheck them on a different display setup or while other GPU applications are open.

On 2026-11-05, the other boot of this SSD reported macOS 26.7 (build 25G229), Intel Core i9, Radeon RX 6900 XT with 16 GiB VRAM, and an integrated Radeon Vega reporting 32 GB shared memory. The runtime selector chose the RX 6900 XT and Large V3; it ignored the Vega memory figure. The RX 5600 + Vega case was checked with the same `system_profiler` parsing logic and selected the 6 GiB RX 5600 / Turbo Q8_0 profile. The active Whisper service on this boot reported `whisper.cpp/OpenCL AMD Radeon RX 6900 XT`.

| Test on RX 5600 | Observed result |
|---|---|
| OpenCL F32 matrix smoke test | Passed on the AMD OpenCL device; maximum absolute error 0.0. |
| Portuguese, 10.00 s, `language` omitted | HTTP 200 in 41.57 s (RTF 4.16); automatic detection selected Portuguese. Output preserved the Portuguese language and accents; this is a short synthetic sample, not a human-speech accuracy score. |
| English, 10.00 s, `language` omitted | HTTP 200 in 41.90 s (RTF 4.19); automatic detection selected English. The short synthetic sample was mostly recognized; one technical word was rendered as “compatriot” instead of “compatible.” |
| OpenHands UI request, 17.76 s recorded audio | The configured app sent the request to the local endpoint and received HTTP 200 in 118.02 s. The test played synthetic speech into a headset output that the headset microphone could not capture, so this validates the app-to-API path only, not natural voice accuracy. |
| Earlier RX 6900 XT reference tests | Large V3 F16 was more accurate than Turbo F16 on a short synthesized mixed-language script (WER 1.8% vs. 17.9%; CER 0.7% vs. 8.2%). This was a small TTS sample, not a human-spontaneous-speech benchmark. The 16 GB RX 6900 XT profile remains full Large V3. |
| OpenHands repair on RX 6900 XT (2026-11-05) | Installed OpenHands 1.35.0 matched the latest official stable release. Local Apple Development signing passed `codesign --verify --deep --strict`; the main app and Electron Renderer helper carry the audio-input entitlement, and the Renderer helper has `NSMicrophoneUsageDescription`. The microphone TCC grant was renewed for the newly signed bundle. Voice Input settings in the running app showed `http://127.0.0.1:8765/v1`, blank API key, and `whisper-1`. The user-provided 5.7 s M4A returned the expected mixed-language sentence through the local API in 29.04 s. A direct Electron capture exercised the local endpoint, but playing the sample through the current speaker did not route intelligible speech into the PD200X microphone, so this run does not claim an end-to-end spoken-text match from the physical mic. |
| LaunchAgent recovery | A child-process failure was deliberately induced; launchd recovered the service and one listener returned on each configured port. The latest daemon also passed its AMD OpenCL preflight. RunAtLoad and KeepAlive are enabled. A fresh logout/reboot test was not performed. |

For the 6 GB RX 5600 the daemon uses Turbo Q8_0, while GPUs with at least 12 GiB use full Large V3 and 8–12 GiB GPUs use unquantized Turbo. This threshold is based on available VRAM and actual RX 5600 model-load/inference checks; it does not promise 1.5 GiB of immediately free VRAM under every display workload. The daemon matches the human-readable `sppci_model` value from `system_profiler` (for example, `AMD Radeon RX 5600`); `_name` is an internal token such as `kHW_AMDRadeonRX5600Item` and cannot be passed as an OpenCL device name.

The daemon now examines all GPUs reported by `system_profiler`, prefers a supported RX card driving the main display, and otherwise chooses the supported RX card with the most VRAM. It deliberately ignores the Radeon Vega's 32 GB shared-memory figure. `scripts/select-amd-gpu.py` contains this selection logic; the daemon's startup preflight still requires the selected AMD OpenCL device and refuses to continue on CPU alone.

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

The OpenHands UI appends `/audio/transcriptions` to the base URL. Microphone capture still requires macOS microphone permission for the Electron app. The optional one-click repair below adds the `com.apple.security.device.audio-input` entitlement and Renderer usage description to the installed OpenHands bundle, then signs that local copy with the user's Apple Development identity. The entitlement plist is an example for this local repair; the Whisper installer by itself does not change OpenHands.

## One-click OpenHands updater and microphone repair

On macOS, the installed double-click utility is `~/Applications/WhisperLocal/Repair OpenHands Microphone.command`. The source version is `release/Repair OpenHands Microphone.command` in this repository. Terminal opens to show progress. The script checks the official OpenHands GitHub latest stable release, downloads the universal DMG only when it is newer than the installed app, verifies the DMG against GitHub's published SHA-256 digest, preserves a pre-change copy, and installs the release. It then adds the microphone usage description to Electron's Renderer helper and signs the app bundle with a valid Apple Development identity from the logged-in user's Keychain and `com.apple.security.device.audio-input` entitlement. It launches OpenHands when finished. OpenHands settings and local Whisper models are stored outside the app bundle and are not removed by this update.

The first successful run also installs the per-user LaunchAgent `local.openhands.agent-canvas.microphone-repair`. It runs at login and checks every 60 seconds for a changed app bundle. When OpenHands is closed, it reapplies the microphone description and signature. It never force-quits a running OpenHands process. If a release update arrives while OpenHands is open, close the app after the update; the next check repairs the bundle before the next launch. Re-running the click utility on an already repaired app does not close it. The LaunchAgent does not download releases on its own; the double-click updater does that.

This local signing uses the Apple Development certificate in that user's Keychain. It is intended to let macOS attribute microphone permission to the Electron app on this Mac; it does not make the upstream OpenHands build Developer ID signed or notarized for distribution. macOS may show a Keychain access prompt on the first run, and may ask the user to grant microphone access again after the bundle identity changes. If that happens, allow microphone access for OpenHands Agent Canvas in System Settings → Privacy & Security → Microphone.

The tool stores its state and logs in `~/Applications/WhisperLocal/config/` and `~/Applications/WhisperLocal/logs/`. The pre-change app copy is kept in `~/Applications/WhisperLocal/backups/`. The repair can be run again safely; it checks the installed version and skips a re-download when current.

To remove the automatic repair watcher, unload and delete its LaunchAgent:

```zsh
launchctl bootout "gui/$(id -u)/local.openhands.agent-canvas.microphone-repair" 2>/dev/null || true
rm "$HOME/Library/LaunchAgents/local.openhands.agent-canvas.microphone-repair.plist"
```

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
