# Changelog

## Unreleased

- Select AMD OpenCL devices by their human-readable `system_profiler` model name, fixing RX 5600 startup.
- Add the multilingual Turbo Q8_0 profile and its OpenCL 1.2 F32 GPU fallback for cards up to 8 GiB.
- Require all three model profiles during installation and download the Q8_0 checkpoint.
- Record RX 5600 API, language-detection, memory, and OpenHands integration measurements.
- Add the Whisper command directory to interactive Zsh sessions during CLI installation.
- Add a one-click OpenHands updater that verifies official GitHub release hashes, repairs microphone signing/usage metadata, and installs a per-user update watcher.
- Select only the RX 6900 XT or RX 5600 for OpenCL and ignore the integrated Vega's shared-memory figure when choosing the Whisper model profile.

## 0.1.0 - 2026-11-01

- Add a loopback OpenAI-compatible transcription adapter for OpenHands.
- Add an Apple OpenCL 1.2 fallback for AMD GPUs without FP16 or subgroup support.
- Add automatic Large V3 / Large V3 Turbo selection based on main-display GPU VRAM.
- Add LaunchAgent, command-line management, model download, build, smoke-test, and release scripts.
