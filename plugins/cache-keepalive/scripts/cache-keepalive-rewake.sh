#!/usr/bin/env bash
# ============================================================
# cache-keepalive-rewake.sh  --  Stop hook (asyncRewake)
# ============================================================
# LOCAL PATCH (2026-10-17): replaces the plugin Monitor, which Claude Code
# only arms in interactive CLI sessions (never in the desktop app).
#
# Runs in the background at the end of every turn (asyncRewake: true). It
# sleeps until the cache has been untouched for CCKA_IDLE_SECONDS, then exits
# 2 with CCKA_PING_TEXT on stderr; Claude Code wakes the session with that
# text, the reply is a cache read, and the TTL is refreshed. The ping turn's
# own Stop arms the next waiter, so nothing has to be re-armed by hand.
#
# One waiter per session: a new waiter, a prompt (stamp hook) or SessionEnd
# kills the previous one through waiter.<session>.pid, so a superseded
# waiter never wakes anybody (a killed asyncRewake hook does not exit 2).
#
# "Last cache touch" = newest of: last_stop.<session> (real activity, written
# by the stamp hook), last_ping.<session> (our own ping) and the transcript's
# mtime (every main-loop message is written there, which also covers turns
# that end without a Stop, e.g. an Esc interrupt).
#
# Config (env first, else ~/.claude/cache-keepalive/config, else default):
#   CCKA_IDLE_SECONDS       untouched before pinging     (default 3000 = 50 min)
#   CCKA_MAX_IDLE_SECONDS   no real activity for this long -> stop pinging
#                                                       (default 43200 = 12h; 0 = never)
#   CCKA_TTL_SECONDS        cache already older than this -> cold, skip (default 3600)
#   CCKA_PING_TEXT          text delivered to Claude
#   CCKA_STATE_DIR / CCKA_LOG / CCKA_ENABLED as in the other scripts
# The hook's "timeout" in hooks.json must stay above CCKA_IDLE_SECONDS.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

CFG="$STATE_DIR/config"
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG" 2>/dev/null || true
fi

input="$(cat 2>/dev/null || true)"
json_field() {
  printf '%s' "$input" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# key preference must match cache-keepalive-stamp.sh
key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$key" ] || key="$(json_field session_id)"
[ -n "$key" ] || key="default"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
transcript="$(json_field transcript_path)"

HB="$STATE_DIR/last_stop.$safe"
PINGFILE="$STATE_DIR/last_ping.$safe"
PIDFILE="$STATE_DIR/waiter.$safe.pid"
LOG="${CCKA_LOG:-$STATE_DIR/cache-keepalive.$safe.log}"

log() { printf '[%s] [CACHE-KEEPALIVE-REWAKE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# --- start-up gates (same as the monitor) --------------------------------
case "$(printf '%s' "${CCKA_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) exit 0 ;;
esac
[ -f "$STATE_DIR/disabled" ] && exit 0
[ -f "$STATE_DIR/disabled.$safe" ] && exit 0
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off" ]; then
  exit 0
fi

IDLE="${CCKA_IDLE_SECONDS:-3000}"
MAX_IDLE="${CCKA_MAX_IDLE_SECONDS:-43200}"
TTL="${CCKA_TTL_SECONDS:-3600}"
MESSAGE="${CCKA_PING_TEXT:-cache-keepalive ping: reply with \"ok\" and nothing else.}"
case "$IDLE"     in ''|*[!0-9]*) IDLE=3000 ;; esac
case "$MAX_IDLE" in ''|*[!0-9]*) MAX_IDLE=43200 ;; esac
case "$TTL"      in ''|*[!0-9]*) TTL=3600 ;; esac
[ "$IDLE" -lt 1 ] && IDLE=3000

# --- one waiter per session ----------------------------------------------
old="$(cat "$PIDFILE" 2>/dev/null || true)"
case "$old" in
  ''|*[!0-9]*) : ;;
  *)
    if [ "$old" != "$$" ]; then
      case "$(ps -p "$old" -o command= 2>/dev/null || true)" in
        *cache-keepalive-rewake*) kill "$old" 2>/dev/null || true ;;
      esac
    fi
    ;;
esac
printf '%s' "$$" > "$PIDFILE" 2>/dev/null || true

_sleep_pid=""
_cleanup() {
  [ -n "$_sleep_pid" ] && kill "$_sleep_pid" 2>/dev/null
  # only clear the pid file if it is still ours; truncate rather than delete,
  # since this runs every turn and `rm` may be a move-to-trash wrapper
  [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ] && : > "$PIDFILE" 2>/dev/null
  return 0
}
trap _cleanup EXIT
trap 'exit 0' INT TERM

num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# let the stamp hook (same Stop event, run in parallel) write first
sleep 1

log "armed (pid=$$ idle=${IDLE}s max_idle=${MAX_IDLE}s ttl=${TTL}s)"

# opportunistic housekeeping (throttled inside), formerly run by the monitor;
# all output discarded so nothing reaches the rewake message
HK="$(dirname "$0")/cache-keepalive-housekeep.sh"
if [ -f "$HK" ]; then
  ( CLAUDE_SESSION_ID="$key" bash "$HK" </dev/null >/dev/null 2>&1 & ) 2>/dev/null || true
fi
while :; do
  now="$(date +%s)"
  real="$(num "$(cat "$HB" 2>/dev/null)")"
  touch_="$real"
  p="$(num "$(cat "$PINGFILE" 2>/dev/null)")"
  [ "$p" -gt "$touch_" ] && touch_="$p"
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    t="$(num "$(mtime_of "$transcript")")"
    [ "$t" -gt "$touch_" ] && [ "$t" -le "$now" ] && touch_="$t"
  fi
  [ "$touch_" -eq 0 ] && touch_="$now"

  if [ "$MAX_IDLE" -gt 0 ] && [ "$real" -gt 0 ] && [ $((now - real)) -ge "$MAX_IDLE" ]; then
    log "no real activity for $(( (now - real) / 3600 ))h >= max_idle; not pinging"
    exit 0
  fi
  since=$((now - touch_))
  if [ "$since" -ge "$TTL" ]; then
    log "cache untouched for ${since}s >= ttl (slept?); not pinging"
    exit 0
  fi
  if [ "$since" -ge "$IDLE" ]; then
    printf '%s' "$now" > "$PINGFILE" 2>/dev/null || true
    log "untouched ${since}s >= ${IDLE}s -> rewaking"
    printf '%s\n' "$MESSAGE" >&2
    exit 2
  fi
  # background sleep + wait so a TERM from the next waiter ends us at once
  sleep $((IDLE - since)) &
  _sleep_pid=$!
  wait "$_sleep_pid" 2>/dev/null
  _sleep_pid=""
done
