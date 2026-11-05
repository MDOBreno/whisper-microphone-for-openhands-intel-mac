#!/usr/bin/env python3
"""Select a supported discrete Radeon for Whisper from system_profiler JSON.

The iMac Hackintosh can expose an integrated Radeon Vega with shared memory as
well as one of the supported RX boards. We deliberately choose only the RX
6900 XT or RX 5600 so shared system memory is never mistaken for VRAM.
"""

from __future__ import annotations

import json
import re
import sys


SUPPORTED = (
    (re.compile(r"\bRX\s*6900\s*XT\b", re.IGNORECASE), 16 * 1024**3),
    (re.compile(r"\bRX\s*5600(?:\s*XT)?\b", re.IGNORECASE), 6 * 1024**3),
)


def vram_bytes(value: object, fallback: int) -> int:
    if not isinstance(value, str):
        return fallback
    match = re.search(r"([\d.]+)\s*(GB|MB)\b", value, re.IGNORECASE)
    if not match:
        return fallback
    number = float(match.group(1))
    unit = match.group(2).upper()
    return int(number * (1024**3 if unit == "GB" else 1024**2))


def select(data: dict) -> tuple[str, int]:
    displays = data.get("SPDisplaysDataType", [])
    candidates = []
    for gpu in displays:
        model = str(gpu.get("sppci_model") or gpu.get("_name") or "")
        matched = next((default_vram for pattern, default_vram in SUPPORTED if pattern.search(model)), None)
        if matched is None:
            continue
        is_main = any(
            display.get("spdisplays_main") == "spdisplays_yes"
            for display in gpu.get("spdisplays_ndrvs", [])
        )
        candidates.append((is_main, vram_bytes(gpu.get("spdisplays_vram"), matched), model))

    if not candidates:
        raise ValueError("No supported discrete AMD GPU found (expected RX 6900 XT or RX 5600).")

    # Prefer the supported board driving the main display. If the monitor is
    # connected to the integrated Vega, pick the supported card with most VRAM.
    is_main, memory, model = max(candidates, key=lambda item: (item[0], item[1]))
    canonical = "AMD Radeon RX 6900 XT" if "6900" in model else "AMD Radeon RX 5600"
    return canonical, memory


def main() -> int:
    try:
        profile = select(json.load(sys.stdin))
    except (json.JSONDecodeError, OSError, ValueError) as exc:
        print(f"GPU profile error: {exc}", file=sys.stderr)
        return 1
    print(f"{profile[0]}\t{profile[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
