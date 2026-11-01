#!/bin/zsh
set -euo pipefail
LABEL="local.whisper.openai"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNTIME_ROOT="${WHISPER_RUNTIME_ROOT:-$HOME/Applications/WhisperLocal}"
action="${1:-$(basename "$0" | sed 's/^whisper-//')}"
case "$action" in
  start)
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl bootstrap "$DOMAIN" "$PLIST"
    else
      launchctl kickstart "$DOMAIN/$LABEL"
    fi
    print "WhisperLocal started via launchd ($LABEL)."
    ;;
  stop)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL"
    fi
    print "WhisperLocal stopped."
    ;;
  restart)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL"
    fi
    launchctl bootstrap "$DOMAIN" "$PLIST"
    print "WhisperLocal restarted via launchd."
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>&1 || true
    printf '\n--- API ---\n'
    /usr/bin/curl -sS --max-time 3 http://127.0.0.1:8765/health || true
    print "\n--- listeners ---"
    /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null || true
    /usr/sbin/lsof -nP -iTCP:8766 -sTCP:LISTEN 2>/dev/null || true
    ;;
  logs)
    /usr/bin/tail -n 100 -F "$RUNTIME_ROOT/logs/service.log" "$RUNTIME_ROOT/logs/service.err"
    ;;
  *) print "Usage: whisper-{status,start,stop,restart,logs}"; exit 2 ;;
esac
