#!/usr/bin/env bash
# LOCAL: tests for the asyncRewake waiter (cache-keepalive-rewake.sh) and the
# stamp/cleanup/ctl changes that go with it. Short timings, temp state dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/plugins/cache-keepalive/scripts"
REWAKE="$S/cache-keepalive-rewake.sh"
STAMP="$S/cache-keepalive-stamp.sh"
CLEANUP="$S/cache-keepalive-cleanup.sh"
CTL="$S/cache-keepalive-ctl.sh"
TMP="$(mktemp -d)"
trap 'pkill -f "$TMP" 2>/dev/null' EXIT   # temp dir is left for the OS to clean
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR
export CCKA_STATE_DIR="$TMP"
pass=0; fail=0
check() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "  ok   $3"; else fail=$((fail+1)); echo "  FAIL $3 (got '$1', want '$2')"; fi; }
inp() { printf '{"session_id":"%s","hook_event_name":"%s","transcript_path":"%s"}' "$1" "$2" "${3:-}"; }
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

echo "-- fires after idle, exit 2, text on stderr, last_ping written --"
date +%s > "$TMP/last_stop.A"
inp A Stop | CCKA_IDLE_SECONDS=2 bash "$REWAKE" 2>"$TMP/err.A"; rc=$?
check "$rc" "2" "exit code 2"
check "$(grep -c '缓存保活唤醒' "$TMP/err.A")" "1" "ping text on stderr"
check "$( [ -s "$TMP/last_ping.A" ] && echo yes || echo no )" "yes" "last_ping.A written"
check "$( [ -s "$TMP/waiter.A.pid" ] && echo yes || echo no )" "no" "pid file removed on exit"

echo "-- per-project supplement and base override --"
check "$(grep -c '本项目补充' "$TMP/err.A")" "0" "no supplement without project file"
mkdir -p "$TMP/projP/.claude"; printf '运行 project-check.sh\n' > "$TMP/projP/.claude/cache-keepalive-ping.md"
date +%s > "$TMP/last_stop.P"
inp P Stop | CLAUDE_PROJECT_DIR="$TMP/projP" CCKA_IDLE_SECONDS=2 bash "$REWAKE" 2>"$TMP/err.P"
check "$(grep -c '缓存保活唤醒' "$TMP/err.P")$(grep -c 'project-check.sh' "$TMP/err.P")" "11" "base text plus project supplement"
date +%s > "$TMP/last_stop.Q"
inp Q Stop | CLAUDE_PROJECT_DIR="$TMP/projP" CCKA_PING_TEXT="custom base" CCKA_IDLE_SECONDS=2 bash "$REWAKE" 2>"$TMP/err.Q"
check "$(grep -c '缓存保活唤醒' "$TMP/err.Q")$(grep -c 'custom base' "$TMP/err.Q")$(grep -c 'project-check.sh' "$TMP/err.Q")" "011" "CCKA_PING_TEXT replaces base, supplement still added"

echo "-- a new waiter supersedes the old one (old exits 0, no rewake) --"
date +%s > "$TMP/last_stop.B"
inp B Stop | CCKA_IDLE_SECONDS=30 bash "$REWAKE" 2>/dev/null & p1=$!
sleep 2
inp B Stop | CCKA_IDLE_SECONDS=30 bash "$REWAKE" 2>/dev/null & p2=$!
sleep 2
wait "$p1"; rc1=$?
check "$rc1" "0" "old waiter exits 0"
check "$(alive "$p2")" "yes" "new waiter still waiting"
check "$(cat "$TMP/waiter.B.pid")" "$p2" "pid file names the new waiter"

echo "-- UserPromptSubmit stamp stops the waiter --"
inp B UserPromptSubmit | bash "$STAMP"
wait "$p2"; rc2=$?
check "$rc2" "0" "waiter exits 0 on prompt"

echo "-- cold cache (older than ttl) -> no ping --"
echo $(( $(date +%s) - 4000 )) > "$TMP/last_stop.C"
inp C Stop | CCKA_IDLE_SECONDS=2 bash "$REWAKE" 2>/dev/null; rc=$?
check "$rc" "0" "exit 0 when cold"
check "$( [ -f "$TMP/last_ping.C" ] && echo yes || echo no )" "no" "no ping written"

echo "-- max idle reached (real activity old, recent ping) -> no ping --"
echo $(( $(date +%s) - 500 )) > "$TMP/last_stop.D"
echo $(( $(date +%s) - 5 ))   > "$TMP/last_ping.D"
inp D Stop | CCKA_IDLE_SECONDS=2 CCKA_MAX_IDLE_SECONDS=300 bash "$REWAKE" 2>/dev/null; rc=$?
check "$rc" "0" "exit 0 past max_idle"

echo "-- per-session disabled marker -> no waiter --"
: > "$TMP/disabled.E"
inp E Stop | CCKA_IDLE_SECONDS=1 bash "$REWAKE" 2>/dev/null; rc=$?
check "$rc" "0" "exit 0 when disabled"
check "$( [ -s "$TMP/waiter.E.pid" ] && echo yes || echo no )" "no" "no pid file when disabled"

echo "-- newer transcript mtime counts as a cache touch --"
echo $(( $(date +%s) - 100 )) > "$TMP/last_stop.F"
: > "$TMP/transcript.F.jsonl"
start=$(date +%s)
inp F Stop "$TMP/transcript.F.jsonl" | CCKA_IDLE_SECONDS=4 bash "$REWAKE" 2>/dev/null; rc=$?
took=$(( $(date +%s) - start ))
check "$rc" "2" "still fires"
check "$( [ "$took" -ge 3 ] && echo yes || echo no )" "yes" "waited for the transcript-based idle (${took}s)"

echo "-- SessionEnd cleanup stops the waiter --"
date +%s > "$TMP/last_stop.G"
inp G Stop | CCKA_IDLE_SECONDS=30 bash "$REWAKE" 2>/dev/null & pg=$!
sleep 2
inp G SessionEnd | bash "$CLEANUP"
wait "$pg"; rc=$?
check "$rc" "0" "waiter exits 0 on SessionEnd"
check "$( [ -s "$TMP/waiter.G.pid" ] && echo yes || echo no )" "no" "pid file gone"

echo "-- ctl off stops this session's waiter --"
date +%s > "$TMP/last_stop.H"
inp H Stop | CCKA_IDLE_SECONDS=30 bash "$REWAKE" 2>/dev/null & ph=$!
sleep 2
CLAUDE_SESSION_ID=H bash "$CTL" off >/dev/null
wait "$ph"; rc=$?
check "$rc" "0" "waiter exits 0 on ctl off"
check "$( [ -f "$TMP/disabled.H" ] && echo yes || echo no )" "yes" "disabled.H written"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
