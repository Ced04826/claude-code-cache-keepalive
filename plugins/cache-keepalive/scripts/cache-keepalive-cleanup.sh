#!/usr/bin/env bash
# ============================================================
# cache-keepalive-cleanup.sh  --  SessionEnd hook
# ============================================================
# Stops this session's background monitor / rewake waiter as part of session
# teardown, so it is not counted as "background work still running" at exit.
# Best-effort: reads the pid files they wrote on startup.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
[ -d "$STATE_DIR" ] || exit 0

input="$(cat 2>/dev/null || true)"

key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$key" ]; then
  key="$(printf '%s' "$input" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
[ -n "$key" ] || key="default"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"

# LOCAL PATCH (2026-10-17): also stop this session's rewake waiter
for PIDFILE in "$STATE_DIR/monitor.$safe.pid" "$STATE_DIR/waiter.$safe.pid"; do
  [ -s "$PIDFILE" ] || continue
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) : ;;
    *)
      # only kill it if it is really ours: a stale pid file can point at
      # a reused pid belonging to something else entirely
      cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      case "$cmd" in
        *cache-keepalive-monitor*|*cache-keepalive-rewake*)
          kill "$pid" 2>/dev/null || true
          for _ in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
          done
          kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
          ;;
        *) : ;;
      esac
      ;;
  esac
  # the waiter's file is rewritten every turn: truncate it rather than delete
  case "$PIDFILE" in
    */waiter.*) : > "$PIDFILE" 2>/dev/null || true ;;
    *) rm -f "$PIDFILE" ;;
  esac
done
exit 0
