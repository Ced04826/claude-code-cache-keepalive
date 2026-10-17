#!/usr/bin/env bash
# ============================================================
# cache-keepalive-stamp.sh  --  Stop + UserPromptSubmit hook
# ============================================================
# Fast, non-blocking. Records "this session was active now" so the
# background monitor can measure how long *this session* has been idle.
#
# Per-session: the heartbeat is keyed by the Claude Code session id
# (CLAUDE_SESSION_ID, falling back to the stdin session_id), so multiple
# concurrent sessions keep independent idle timers. A global last_stop
# is also written as a fallback for a monitor that cannot see a session id.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

input="$(cat 2>/dev/null || true)"
now="$(date +%s)"

# key preference must match the monitor: env first, then the hook's stdin
key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$key" ]; then
  key="$(printf '%s' "$input" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
[ -n "$key" ] || key="default"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"

# LOCAL PATCH (2026-10-12): the Stop that ends the monitor's own ping turn is
# not user activity. Without this, every ping resets the idle clock and
# CCKA_MAX_IDLE_SECONDS can never be reached. A real prompt always goes through
# UserPromptSubmit first, which stamps and makes last_stop newer than last_ping.
event="$(printf '%s' "$input" \
  | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [ "$event" = "Stop" ]; then
  lp="$(cat "$STATE_DIR/last_ping.$safe" 2>/dev/null || echo 0)"
  ls_="$(cat "$STATE_DIR/last_stop.$safe" 2>/dev/null || echo 0)"
  case "$lp" in ''|*[!0-9]*) lp=0 ;; esac
  case "$ls_" in ''|*[!0-9]*) ls_=0 ;; esac
  if [ "$lp" -gt "$ls_" ] && [ $((now - lp)) -lt 600 ]; then
    exit 0
  fi
fi

printf '%s' "$now" > "$STATE_DIR/last_stop.$safe" 2>/dev/null || true
printf '%s' "$now" > "$STATE_DIR/last_stop"       2>/dev/null || true   # fallback
printf '%s' "$safe" > "$STATE_DIR/last_session"   2>/dev/null || true

exit 0
