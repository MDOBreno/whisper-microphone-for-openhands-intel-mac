#!/bin/zsh
set -euo pipefail

MODE="${1:---update-and-repair}"
APP_ID="dev.openhands.agent-canvas"
APP_NAME="OpenHands Agent Canvas"
APP_PATH="${OPENHANDS_APP_PATH:-}"
RUNTIME_ROOT="${WHISPER_RUNTIME_ROOT:-$HOME/Applications/WhisperLocal}"
LOG_DIR="$RUNTIME_ROOT/logs"
CONFIG_DIR="$RUNTIME_ROOT/config"
BACKUP_DIR="$RUNTIME_ROOT/backups"
STATE_FILE="$CONFIG_DIR/openhands-microphone-repair.state"
LOCK_DIR="$RUNTIME_ROOT/tmp/openhands-microphone-repair.lock"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
LOG_FILE="$LOG_DIR/openhands-microphone-repair.log"
ENTITLEMENTS="$CONFIG_DIR/openhands-microphone.entitlements.plist"
IDENTITY_FILE="$CONFIG_DIR/openhands-signing-identity.txt"
AGENT_LABEL="local.openhands.agent-canvas.microphone-repair"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
ACTIVE_MOUNT=""

mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$RUNTIME_ROOT/tmp" "$RUNTIME_ROOT/scripts" "$HOME/Library/LaunchAgents"
if [[ "$MODE" != "--watch" ]]; then
  exec > >(/usr/bin/tee -a "$LOG_FILE") 2>&1
fi

log() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*"; }
fail() { log "ERROR: $*"; exit 1; }

if [[ -z "$APP_PATH" ]]; then
  if [[ -d "/Applications/$APP_NAME.app" ]]; then
    APP_PATH="/Applications/$APP_NAME.app"
  elif [[ -d "$HOME/Applications/$APP_NAME.app" ]]; then
    APP_PATH="$HOME/Applications/$APP_NAME.app"
  else
    fail "Could not find $APP_NAME.app in /Applications or ~/Applications."
  fi
fi
[[ -d "$APP_PATH/Contents" ]] || fail "App bundle not found at: $APP_PATH"

APP_INFO="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO" 2>/dev/null || true)"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO" 2>/dev/null || true)"
[[ "$APP_BUNDLE_ID" == "$APP_ID" ]] || fail "Unexpected bundle ID '$APP_BUNDLE_ID' at $APP_PATH."
[[ -n "$APP_VERSION" ]] || fail "Could not read the installed OpenHands version."

main_executable="$APP_PATH/Contents/MacOS/$APP_NAME"
renderer="$APP_PATH/Contents/Frameworks/$APP_NAME Helper (Renderer).app"
renderer_info="$renderer/Contents/Info.plist"
[[ -x "$main_executable" ]] || fail "OpenHands executable is missing: $main_executable"
[[ -f "$renderer_info" ]] || fail "Electron Renderer helper is missing: $renderer"

if [[ "$SCRIPT_DIR/openhands-microphone-repair.zsh" != "$RUNTIME_ROOT/scripts/openhands-microphone-repair.zsh" ]]; then
  /usr/bin/install -m 755 "$SCRIPT_DIR/openhands-microphone-repair.zsh" "$RUNTIME_ROOT/scripts/openhands-microphone-repair.zsh"
fi
if [[ "$PROJECT_ROOT/config/openhands-microphone.entitlements.plist" != "$ENTITLEMENTS" ]]; then
  /usr/bin/install -m 644 "$PROJECT_ROOT/config/openhands-microphone.entitlements.plist" "$ENTITLEMENTS"
fi

if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && /bin/kill -0 "$old_pid" 2>/dev/null; then
    log "Another OpenHands repair is already running (PID $old_pid); leaving it alone."
    exit 0
  fi
  /bin/rm -rf "$LOCK_DIR"
  /bin/mkdir "$LOCK_DIR" 2>/dev/null || { log "Repair lock is busy; skipping this run."; exit 0; }
fi
print -r -- "$$" > "$LOCK_DIR/pid"
cleanup() {
  if [[ -n "$ACTIVE_MOUNT" ]]; then /usr/bin/hdiutil detach "$ACTIVE_MOUNT" -quiet >/dev/null 2>&1 || true; fi
  /bin/rm -rf "$LOCK_DIR"
}
trap cleanup EXIT INT TERM HUP

is_app_running() {
  /usr/bin/pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1
}

ensure_app_closed() {
  if ! is_app_running; then return 0; fi
  if [[ "$MODE" == "--watch" ]]; then
    log "OpenHands is open; deferring bundle changes until the app is closed."
    return 1
  fi
  /usr/bin/osascript <<APPLESCRIPT
set answer to display dialog "OpenHands must close briefly so its update and microphone signature can be applied. Save your work, then choose Continue." buttons {"Cancel", "Continue"} default button "Continue" with title "Repair OpenHands microphone"
if button returned of answer is "Continue" then
  tell application id "$APP_ID" to quit
end if
APPLESCRIPT
  for _ in {1..45}; do
    if ! is_app_running; then return 0; fi
    /bin/sleep 1
  done
  log "OpenHands did not quit; no files were changed. Close it and run the repair again."
  return 1
}

backup_current_app() {
  local version="$1"
  local existing
  existing="$(/usr/bin/find "$BACKUP_DIR" -maxdepth 1 -type d -name "$APP_NAME $version *.app" -print -quit 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    log "Keeping existing pre-change backup: $existing"
    return 0
  fi
  local target="$BACKUP_DIR/$APP_NAME $version before microphone repair.app"
  log "Saving a recoverable copy at: $target"
  /usr/bin/ditto "$APP_PATH" "$target"
}

get_release_metadata() {
  /usr/bin/curl --fail --silent --show-error --location --retry 2 --connect-timeout 20 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    'https://api.github.com/repos/OpenHands/OpenHands/releases/latest' |
    /usr/bin/python3 -c '
import json, re, sys
release = json.load(sys.stdin)
tag = release.get("tag_name", "")
version = tag.removeprefix("v")
if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Latest OpenHands release tag is not a stable x.y.z version")
expected = f"OpenHands-Agent-Canvas-{version}-universal.dmg"
asset = next((a for a in release.get("assets", []) if a.get("name") == expected), None)
if asset is None:
    raise SystemExit(f"Official universal macOS DMG is missing from release {tag}")
digest = asset.get("digest", "")
url = asset.get("browser_download_url", "")
if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
    raise SystemExit("GitHub did not provide the official SHA-256 digest; refusing an unverifiable update")
if not url.startswith("https://github.com/OpenHands/OpenHands/releases/download/"):
    raise SystemExit("Release asset URL is outside the official OpenHands GitHub release host")
print("\t".join((version, url, digest.split(":", 1)[1])))
'
}

is_version_newer() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import re, sys
def version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){1,3}", value):
        raise SystemExit(2)
    return tuple(int(part) for part in value.split("."))
a, b = version(sys.argv[1]), version(sys.argv[2])
width = max(len(a), len(b))
sys.exit(0 if a + (0,) * (width-len(a)) > b + (0,) * (width-len(b)) else 1)
PY
}

install_latest_release() {
  local metadata latest_version download_url expected_digest
  if ! metadata="$(get_release_metadata 2>/dev/null)"; then
    log "Could not verify the latest release online; continuing with microphone repair for installed OpenHands $APP_VERSION."
    return 0
  fi
  IFS=$'\t' read -r latest_version download_url expected_digest <<< "$metadata"
  [[ -n "$latest_version" && -n "$download_url" ]] || fail "The official release metadata was incomplete."

  if ! is_version_newer "$latest_version" "$APP_VERSION"; then
    log "OpenHands $APP_VERSION is already current (latest official stable release: $latest_version)."
    return 0
  fi

  log "Official OpenHands update found: $APP_VERSION -> $latest_version."
  ensure_app_closed || fail "Close OpenHands before installing the update."
  backup_current_app "$APP_VERSION"

  local work mount dmg source_app staged_app old_app actual_digest downloaded_id downloaded_version previous_version
  previous_version="$APP_VERSION"
  work="$(/usr/bin/mktemp -d "$RUNTIME_ROOT/tmp/openhands-release.XXXXXX")"
  mount="$work/mount"
  dmg="$work/OpenHands-Agent-Canvas-$latest_version-universal.dmg"
  staged_app="$(dirname -- "$APP_PATH")/.$APP_NAME.update-stage.app"
  old_app="$work/$APP_NAME previous.app"
  /bin/mkdir -p "$mount"

  log "Downloading the official universal macOS DMG."
  /usr/bin/curl --fail --silent --show-error --location --retry 2 --connect-timeout 20 --max-time 900 \
    "$download_url" -o "$dmg" || fail "OpenHands DMG download failed."
  actual_digest="$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')"
  [[ "${actual_digest:l}" == "${expected_digest:l}" ]] || fail "Downloaded DMG SHA-256 does not match GitHub's release digest."

  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null || fail "Could not mount the downloaded OpenHands DMG."
  ACTIVE_MOUNT="$mount"
  source_app="$(/usr/bin/find "$mount" -maxdepth 3 -type d -name "$APP_NAME.app" -print -quit)"
  [[ -n "$source_app" ]] || fail "The official DMG does not contain $APP_NAME.app."
  downloaded_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
  downloaded_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
  [[ "$downloaded_id" == "$APP_ID" && "$downloaded_version" == "$latest_version" ]] || fail "DMG bundle identity/version did not match the verified GitHub release."

  /bin/rm -rf "$staged_app"
  /usr/bin/ditto "$source_app" "$staged_app"
  /usr/bin/hdiutil detach "$mount" -quiet || true
  ACTIVE_MOUNT=""

  log "Installing OpenHands $latest_version."
  /bin/mv "$APP_PATH" "$old_app"
  if ! /bin/mv "$staged_app" "$APP_PATH"; then
    /bin/mv "$old_app" "$APP_PATH"
    fail "App replacement failed; restored the previous OpenHands bundle."
  fi
  APP_VERSION="$latest_version"
  log "Previous version $previous_version is preserved in $BACKUP_DIR."
  /bin/rm -rf "$old_app" "$work"
  log "Installed verified OpenHands $APP_VERSION."
}

resolve_signing_identity() {
  local configured="${OPENHANDS_SIGNING_IDENTITY:-}"
  if [[ -z "$configured" && -s "$IDENTITY_FILE" ]]; then
    configured="$(/usr/bin/tr -d '\r\n' < "$IDENTITY_FILE")"
  fi
  local identities
  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ -z "$configured" ]]; then
    configured="$(print -r -- "$identities" | /usr/bin/sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' | /usr/bin/head -1)"
  fi
  [[ -n "$configured" ]] || fail "No valid Apple Development code-signing identity is available in this user's Keychain."
  print -r -- "$identities" | /usr/bin/grep -Fq "\"$configured\"" || fail "Configured signing identity is not currently valid: $configured"
  print -r -- "$configured"
}

bundle_fingerprint() {
  /usr/bin/stat -f '%m:%z' "$APP_INFO" "$main_executable" "$renderer_info" "$renderer/Contents/MacOS/$APP_NAME Helper (Renderer)" 2>/dev/null | /usr/bin/tr '\n' '|'
}

signature_is_current() {
  local details fingerprint saved entitlements renderer_description
  details="$(/usr/bin/codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
  print -r -- "$details" | /usr/bin/grep -Fq "Authority=$SIGNING_IDENTITY" || return 1
  entitlements="$(/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 || true)"
  print -r -- "$entitlements" | /usr/bin/grep -Fq 'com.apple.security.device.audio-input' || return 1
  renderer_description="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$renderer_info" 2>/dev/null || true)"
  [[ "$renderer_description" == *microphone* || "$renderer_description" == *Microphone* ]] || return 1
  fingerprint="$(bundle_fingerprint)"
  saved="$(cat "$STATE_FILE" 2>/dev/null || true)"
  [[ "$saved" == "$APP_VERSION|$fingerprint|$SIGNING_IDENTITY" ]]
}

write_repair_agent() {
  /usr/bin/python3 - "$AGENT_PLIST" "$RUNTIME_ROOT/scripts/openhands-microphone-repair.zsh" "$LOG_FILE" "$AGENT_LABEL" <<'PY'
import plistlib, sys
path, script, log, label = sys.argv[1:]
payload = {
  "Label": label,
  "ProgramArguments": ["/bin/zsh", script, "--watch"],
  "RunAtLoad": True,
  "StartInterval": 60,
  "ThrottleInterval": 60,
  "ProcessType": "Interactive",
  "StandardOutPath": log,
  "StandardErrorPath": log,
}
with open(path, "wb") as output:
    plistlib.dump(payload, output, sort_keys=True)
PY
  /usr/sbin/chown "$(id -un)" "$AGENT_PLIST"
  /bin/chmod 644 "$AGENT_PLIST"
  local domain="gui/$(id -u)"
  /bin/launchctl bootout "$domain/$AGENT_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "$domain" "$AGENT_PLIST"
  log "Installed automatic update repair LaunchAgent ($AGENT_LABEL; login + 60-second check)."
}

SIGNING_IDENTITY="$(resolve_signing_identity)"
log "OpenHands=$APP_VERSION app=$APP_PATH signing identity=$SIGNING_IDENTITY"

if [[ "$MODE" == "--watch" ]]; then
  if signature_is_current; then exit 0; fi
  if is_app_running; then
    log "OpenHands bundle changed while the app is running; repair queued until it closes."
    exit 0
  fi
else
  [[ "$MODE" == "--update-and-repair" || "$MODE" == "--repair-only" ]] || fail "Unknown mode: $MODE"
  if [[ "$MODE" == "--update-and-repair" ]]; then install_latest_release; fi
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
  if ! signature_is_current; then
    ensure_app_closed || fail "Close OpenHands before signing the updated bundle."
  fi
fi

if signature_is_current; then
  log "OpenHands $APP_VERSION already has the microphone fix and a valid local signature."
else
  backup_current_app "$APP_VERSION"
  for plist in "$APP_INFO" "$renderer_info"; do
    if ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$plist" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string This app needs access to the microphone' "$plist"
    fi
  done
  log "Signing OpenHands and Electron helpers with the microphone input entitlement."
  /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_PATH" || fail "codesign failed. If Keychain asks, approve access to the selected Apple Development key and rerun."
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" || fail "The signed OpenHands bundle did not pass deep signature verification."
  local_authority="$(/usr/bin/codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
  print -r -- "$local_authority" | /usr/bin/grep -Fq "Authority=$SIGNING_IDENTITY" || fail "OpenHands was signed, but the resulting signer does not match the selected identity."
  /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS" >/dev/null 2>&1 || fail "Microphone entitlement is missing from the signing profile."
  fingerprint="$(bundle_fingerprint)"
  print -r -- "$APP_VERSION|$fingerprint|$SIGNING_IDENTITY" > "$STATE_FILE"
  /bin/chmod 600 "$STATE_FILE"
  log "Signature verified for OpenHands $APP_VERSION; Electron Renderer includes NSMicrophoneUsageDescription."
fi

if [[ "$MODE" != "--watch" ]]; then
  write_repair_agent
  api_health="$(/usr/bin/curl -fsS --max-time 3 http://127.0.0.1:8765/health 2>/dev/null || true)"
  if [[ -n "$api_health" ]]; then log "Local Whisper API is healthy: $api_health"; else log "Local Whisper API did not answer at 127.0.0.1:8765; the OpenHands microphone permission repair itself is complete."; fi
  log "Launching OpenHands. Any macOS microphone prompt must be allowed for this app."
  /usr/bin/open -a "$APP_PATH"
  log "Done. On future app updates, the LaunchAgent will reapply the signature after OpenHands is closed."
fi
