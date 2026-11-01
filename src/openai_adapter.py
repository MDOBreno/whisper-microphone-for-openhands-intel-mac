#!/usr/bin/env python3
"""Loopback OpenAI transcription adapter for whisper.cpp's /inference endpoint."""
from __future__ import annotations

import email
import email.policy
import json
import math
import os
import re
import struct
import shutil
import subprocess
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8765
BACKEND = os.environ.get("WHISPER_BACKEND_URL", "http://127.0.0.1:8766/inference")
MAX_BYTES = 250 * 1024 * 1024
MAX_SECONDS = 600
FFMPEG = os.environ.get("WHISPER_FFMPEG", shutil.which("ffmpeg") or "/usr/local/bin/ffmpeg")
ONE_AT_A_TIME = threading.BoundedSemaphore(1)
LANGUAGE_WINDOW_SECONDS = 6.0
LANGUAGE_STEP_SECONDS = 6.0
MIN_FINAL_WINDOW_SECONDS = 3.0
WINDOW_CONTEXT_OVERLAP_SECONDS = 0.45


def rms_for_wav(path: Path) -> float:
    with wave.open(str(path), "rb") as wav:
        sample_bytes = wav.readframes(wav.getnframes())
    sampled = (struct.unpack_from("<h", sample_bytes, i)[0] for i in range(0, len(sample_bytes) - 1, 200))
    count = max(1, len(sample_bytes) // 200)
    return math.sqrt(sum(value * value for value in sampled) / count) / 32768.0


def language_windows(duration: float, explicit_language: str | None, wav_path: Path) -> list[tuple[float, float]]:
    # Keep one pass for short recordings and caller-pinned language. For longer
    # auto-detected recordings, prefer nearby quiet points so words are not cut
    # in half and a later language change can be detected independently.
    if explicit_language and explicit_language.lower() != "auto":
        return [(0.0, duration)]
    if duration <= 12.0:
        return [(0.0, duration)]
    with wave.open(str(wav_path), "rb") as wav:
        rate = wav.getframerate()
        pcm = wav.readframes(wav.getnframes())
    values = struct.unpack("<%dh" % (len(pcm) // 2), pcm)
    frame_samples = max(1, int(rate * 0.02))
    frame_rms = []
    for offset in range(0, len(values), frame_samples):
        frame = values[offset:offset + frame_samples]
        if frame:
            frame_rms.append(math.sqrt(sum(sample * sample for sample in frame) / len(frame)) / 32768.0)
    threshold = max(0.0002, min(0.003, rms_for_wav(wav_path) * 0.15))
    boundaries = []
    target = LANGUAGE_STEP_SECONDS
    while target < duration - MIN_FINAL_WINDOW_SECONDS:
        lower = max((boundaries[-1] if boundaries else 0.0) + 3.0, target - 2.0)
        upper = min(duration - MIN_FINAL_WINDOW_SECONDS, target + 2.0)
        candidates = []
        i0 = max(0, int(lower / 0.02))
        i1 = min(len(frame_rms), int(upper / 0.02))
        run_start = None
        for i in range(i0, i1 + 1):
            quiet = i < i1 and frame_rms[i] <= threshold
            if quiet and run_start is None:
                run_start = i
            elif not quiet and run_start is not None:
                if i - run_start >= 5:  # at least 100 ms of low energy
                    candidates.append((run_start + i) / 2 * 0.02)
                run_start = None
        boundary = min(candidates, key=lambda value: abs(value - target)) if candidates else target
        if boundary - (boundaries[-1] if boundaries else 0.0) >= 3.0:
            boundaries.append(boundary)
        target += LANGUAGE_STEP_SECONDS
    points = [0.0] + boundaries + [duration]
    return [(points[i], points[i + 1]) for i in range(len(points) - 1) if points[i + 1] - points[i] > 0.1]


def merge_window_texts(chunks: list[str]) -> str:
    """Join overlapping Whisper windows and remove duplicated boundary words."""
    merged: list[str] = []
    def norm(word: str) -> str:
        return "".join(ch for ch in word.casefold() if ch.isalnum())
    for chunk in chunks:
        words = chunk.strip().split()
        if not words:
            continue
        if not merged:
            merged.extend(words)
            continue
        max_overlap = min(10, len(merged), len(words))
        overlap = 0
        for size in range(max_overlap, 0, -1):
            left = [norm(w) for w in merged[-size:]]
            right = [norm(w) for w in words[:size]]
            if all(left) and left == right and (size > 1 or len(left[0]) >= 5):
                overlap = size
                break
        merged.extend(words[overlap:])
    text = " ".join(merged)
    # Tidy spaces before punctuation after joining window-level outputs.
    for punctuation in (",", ".", "?", "!", ";", ":"):
        text = text.replace(" " + punctuation, punctuation)
    return text


def merge_timed_windows(results: list[dict]) -> str:
    """Join non-overlapping windows without dropping repeated spoken words."""
    return merge_window_texts([result.get("text", "") for result in results])


def normalize_technical_terms(text: str) -> str:
    # Correct common phonetic spellings of the user's software vocabulary;
    # this changes recognized words only and does not prime the language model.
    replacements = (
        (r"\b(?:cloud|claude)\s+code\b", "Claude Code"),
        (r"\bopen\s+hands\b|\bopen\s+hand\s+is\b|\bopen\s+andes\b|\bopenhandis\b|\bopenandis\b|\bopenandes\b|\bopenands\b|\bopenamg\b|\bopenams\b", "OpenHands"),
        (r"\bnode\s*\.\s*js\b|\bnode\s+js\b", "Node.js"),
        (r"\btype\s*script\b", "TypeScript"),
        (r"\bact\s+ions\b", "Actions"),
        (r"\bactions\b", "Actions"),
        (r"\bfal\s+hando\b", "falhando"),
        (r"\bcomit[eê]\s+no\s+guite\b", "commit no Git"),
        (r"\b(?:work|worc|osc)\s*flow\b", "workflow"),
        (r"\b(?:git\s+hub|gith\s*ub|gitub)\b", "GitHub"),
        (r"\bgithub\b", "GitHub"),
        (r"\breact\b", "React"),
        (r"\bapis\b", "APIs"),
        (r"\bapi\b", "API"),
        (r"\bqwen\b", "Qwen"),
        (r"\bmcp\b", "MCP"),
        (r"\bswift\b", "Swift"),
        (r"\bgit\b", "Git"),
    )
    for pattern, replacement in replacements:
        text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
    return text


def post_to_backend(wav_path: Path, fields: dict[str, str], start: float, duration: float) -> dict:
    boundary = "----whisperlocal" + str(time.time_ns())
    parts = []
    def field(key, value):
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n".encode())
    payload = wav_path.read_bytes()
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode() + payload + b"\r\n")
    field("response_format", "verbose_json")
    field("temperature", "0.0")
    field("language", fields.get("language") or "auto")
    if fields.get("prompt"):
        field("prompt", fields["prompt"])
    parts.append(f"--{boundary}--\r\n".encode())
    request = urllib.request.Request(BACKEND, data=b"".join(parts), headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
    with urllib.request.urlopen(request, timeout=MAX_SECONDS + 60) as response:
        result = json.loads(response.read().decode("utf-8"))
    result["window_start"] = start
    result["window_duration"] = duration
    return result


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    server_version = "WhisperLocalOpenAI/1.0"
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        origin = self.headers.get("Origin", "")
        if origin in ("http://localhost:8000", "http://127.0.0.1:8000", "http://localhost:8765", "http://127.0.0.1:8765"):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
            self.send_header("Vary", "Origin")
        super().end_headers()

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {self.client_address[0]} {fmt % args}", flush=True)

    def respond(self, status, body, content_type="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/health", "/v1/models"):
            self.respond(200, json.dumps({
                "ok": True,
                "model": os.environ.get("WHISPER_MODEL_NAME", "large-v3"),
                "backend": os.environ.get("WHISPER_BACKEND_NAME", "whisper.cpp"),
                "language_detection": "per-window",
            }))
        else:
            self.respond(404, json.dumps({"error": {"message": "Not found", "type": "invalid_request_error"}}))

    def do_OPTIONS(self):
        if self.headers.get("Origin", "") not in ("http://localhost:8000", "http://127.0.0.1:8000", "http://localhost:8765", "http://127.0.0.1:8765"):
            return self.respond(403, json.dumps({"error": {"message": "Origin not allowed", "type": "invalid_request_error"}}))
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path != "/v1/audio/transcriptions":
            self.close_connection = True
            return self.respond(404, json.dumps({"error": {"message": "Not found", "type": "invalid_request_error"}}))
        if self.headers.get("Host", "").split(":")[0] not in ("127.0.0.1", "localhost"):
            self.close_connection = True
            return self.respond(403, json.dumps({"error": {"message": "Loopback requests only", "type": "invalid_request_error"}}))
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BYTES:
            self.close_connection = True
            return self.respond(413, json.dumps({"error": {"message": "Audio request must be between 1 byte and 250 MiB", "type": "invalid_request_error"}}))
        if not ONE_AT_A_TIME.acquire(blocking=False):
            # The body has not been consumed; close this HTTP/1.1 connection so
            # the multipart payload cannot be parsed as a second request line.
            self.close_connection = True
            return self.respond(503, json.dumps({"error": {"message": "A transcription is already running; retry shortly", "type": "server_error"}}))
        started = time.monotonic()
        try:
            raw = self.rfile.read(length)
            msg = email.message_from_bytes(
                (f"Content-Type: {self.headers.get('Content-Type', '')}\r\nMIME-Version: 1.0\r\n\r\n").encode() + raw,
                policy=email.policy.default,
            )
            fields = {}
            upload = None
            for part in msg.iter_parts():
                name = part.get_param("name", header="content-disposition")
                data = part.get_payload(decode=True) or b""
                if name == "file":
                    upload = (part.get_filename() or "audio.bin", data)
                elif name:
                    fields[name] = data.decode("utf-8", "replace")
            if not upload or not upload[1]:
                return self.respond(400, json.dumps({"error": {"message": "Missing multipart field 'file'", "type": "invalid_request_error"}}))
            model = fields.get("model", "whisper-1")
            if model not in ("whisper-1", "large-v3", "ggml-large-v3.bin", "large-v3-turbo", "ggml-large-v3-turbo.bin"):
                return self.respond(400, json.dumps({"error": {"message": f"Unknown local model: {model}", "type": "invalid_request_error"}}))
            response_format = fields.get("response_format", "json")
            if response_format not in ("json", "text", "verbose_json"):
                return self.respond(400, json.dumps({"error": {"message": "Only json, verbose_json, and text response formats are supported", "type": "invalid_request_error"}}))
            with tempfile.TemporaryDirectory(prefix="whisperlocal-") as temp_dir:
                input_path = Path(temp_dir) / Path(upload[0]).name
                wav_path = Path(temp_dir) / "normalized.wav"
                input_path.write_bytes(upload[1])
                conv = subprocess.run(
                    [FFMPEG, "-nostdin", "-v", "error", "-y", "-i", str(input_path), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav_path)],
                    capture_output=True, timeout=120,
                )
                if conv.returncode:
                    detail = conv.stderr.decode("utf-8", "replace")[-1200:]
                    return self.respond(415, json.dumps({"error": {"message": "Could not decode audio locally: " + detail, "type": "invalid_request_error"}}))
                duration = wav_path.stat().st_size / 32000.0
                if duration > MAX_SECONDS:
                    return self.respond(413, json.dumps({"error": {"message": "Audio exceeds the 600 second limit", "type": "invalid_request_error"}}))
                # Whisper can invent plausible text for digital silence. Sample
                # at 160 Hz to cheaply detect near-silence while preserving quiet
                # speech. The WAV is guaranteed 16-bit mono by the FFmpeg step.
                rms = rms_for_wav(wav_path)
                if rms < 0.001:
                    print(f"silence guard duration={duration:.2f}s rms={rms:.6f}; skipped inference", flush=True)
                    if response_format == "text":
                        return self.respond(200, "", "text/plain; charset=utf-8")
                    if response_format == "verbose_json":
                        return self.respond(200, json.dumps({"text": "", "task": "transcribe", "language": None, "duration": duration}))
                    return self.respond(200, json.dumps({"text": ""}))
                try:
                    results = []
                    windows = language_windows(duration, fields.get("language"), wav_path)
                    for index, (start, end) in enumerate(windows):
                        segment_path = wav_path
                        if len(windows) > 1:
                            segment_path = Path(temp_dir) / f"window-{index:03d}.wav"
                            segment_start = max(
                                0.0,
                                start - (WINDOW_CONTEXT_OVERLAP_SECONDS if index > 0 else 0.0),
                            )
                            segment_end = min(
                                duration,
                                end + (WINDOW_CONTEXT_OVERLAP_SECONDS if index + 1 < len(windows) else 0.0),
                            )
                            segment = subprocess.run(
                                [FFMPEG, "-nostdin", "-v", "error", "-y", "-ss", f"{segment_start:.3f}", "-i", str(wav_path), "-t", f"{segment_end-segment_start:.3f}", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(segment_path)],
                                capture_output=True, timeout=120,
                            )
                            if segment.returncode:
                                detail = segment.stderr.decode("utf-8", "replace")[-1200:]
                                return self.respond(500, json.dumps({"error": {"message": "Could not split audio for language detection: " + detail, "type": "server_error"}}))
                        segment_rms = rms_for_wav(segment_path)
                        if segment_rms < 0.001:
                            print(f"silence window start={start:.2f}s duration={end-start:.2f}s rms={segment_rms:.6f}; skipped", flush=True)
                            continue
                        result = post_to_backend(segment_path, fields, start, end-start)
                        results.append(result)
                        print(f"window start={start:.2f}s duration={end-start:.2f}s language={result.get('detected_language', result.get('language', 'unknown'))} chars={len(result.get('text', ''))}", flush=True)
                except urllib.error.HTTPError as exc:
                    detail = exc.read().decode("utf-8", "replace")[:2000]
                    return self.respond(502, json.dumps({"error": {"message": f"whisper-server returned HTTP {exc.code}: {detail}", "type": "server_error"}}))
                except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                    return self.respond(502, json.dumps({"error": {"message": f"whisper-server request failed: {exc}", "type": "server_error"}}))
            text = normalize_technical_terms(merge_timed_windows(results))
            languages = [result.get("detected_language") or result.get("language") for result in results]
            languages = [language for language in languages if language]
            elapsed = time.monotonic() - started
            print(f"transcription duration={duration:.2f}s windows={len(results)} languages={','.join(languages)} total={elapsed:.2f}s rtf={elapsed/max(duration,0.001):.3f} chars={len(text)}", flush=True)
            if response_format == "text":
                return self.respond(200, text, "text/plain; charset=utf-8")
            if response_format == "verbose_json":
                return self.respond(200, json.dumps({"text": text, "task": "transcribe", "language": languages[0] if languages else None, "duration": duration}, ensure_ascii=False))
            self.respond(200, json.dumps({"text": text}, ensure_ascii=False))
        except subprocess.TimeoutExpired:
            self.respond(504, json.dumps({"error": {"message": "Local audio conversion timed out", "type": "server_error"}}))
        except Exception as exc:
            traceback.print_exc()
            self.respond(500, json.dumps({"error": {"message": str(exc), "type": "server_error"}}))
        finally:
            ONE_AT_A_TIME.release()


if __name__ == "__main__":
    print(f"Whisper OpenAI adapter listening on http://{HOST}:{PORT}; backend={BACKEND}", flush=True)
    Server((HOST, PORT), Handler).serve_forever()
