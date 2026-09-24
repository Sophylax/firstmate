#!/usr/bin/env bash
# Live driver for the herdr backend, inside a throwaway fm-lab-* session owned
# by bin/fm-herdr-lab.sh (prepare/provision ... teardown). The supervisor pane
# runs a drawn "❯ " composer that registers itself as a herdr agent via
# `pane report-agent` (idle/working around each submission, as
# tests/fm-afk-inject-herdr-e2e.test.sh does) and logs every submitted line.
#
# Phase 1 (direct): inject_msg with a 200,000-byte message through the real
#   herdr CLI, to capture the initial-send failure log line (real E2BIG).
# Phase 2 (daemon): the real daemon with three ~78 KB unread status spans, so
#   the start-up catch-all scan buffers ~236 KB (issue #4382 trigger).
#
# Usage: live-herdr-oversized-digest.sh <lab-helper> <firstmate-root> <out-dir> [run-secs]
set -u
LAB=$1 ROOT=$2 OUT=$3 RUN_SECS=${4:-80}
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
mkdir -p "$OUT"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SESSION=$("$LAB" name afkdigest) || exit 1
printf '%s\n' "$SESSION" > "$OUT/lab-session.txt"
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-digest.XXXXXX")
SUBMITTED="$STATE/submitted.log"; : > "$SUBMITTED"
DPID=
cleanup() {
  [ -z "$DPID" ] || { rm -f "$STATE/.afk"; kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }
  "$LAB" teardown "$SESSION" > "$OUT/lab-teardown.txt" 2>&1; echo "teardown rc=$?" >> "$OUT/lab-teardown.txt"
  rm -rf "$STATE"
}
trap cleanup EXIT
"$LAB" provision "$SESSION" || exit 1
export HERDR_SESSION="$SESSION"

# shellcheck source=/dev/null
. "$DAEMON"
fm_backend_source herdr || exit 1
CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || { echo "container_ensure failed" >&2; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED=${CONTAINER_RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-afk-digest-supervisor /tmp "$SEEDED") || exit 1
read -r _TAB PANE <<EOF
$IDS
EOF
TARGET="$SESSION:$PANE"
ready=0
for _ in $(seq 1 100); do
  if fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null | jq -e '
      .result.process_info as $p | ($p.foreground_processes | length == 1)
      and ($p.foreground_processes[0].pid == $p.shell_pid)' >/dev/null 2>&1; then
    ready=$((ready + 1)); [ "$ready" -ge 10 ] && break
  else ready=0; fi
  sleep 0.1
done

cat > "$STATE/loop.sh" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
rep() { herdr pane report-agent "$HERDR_PANE_ID" --source fm-test-supervisor --agent fm-test-supervisor --state "$1" --session "$HERDR_SESSION" >/dev/null 2>&1; }
stty -echo -icanon min 1 time 0 2>/dev/null
rep idle
_buf=
redraw() { local s=$_buf; [ "${#s}" -le 40 ] || s="...${s: -37}"; printf '\r\033[K❯ %s' "$s"; }
submit_line() { printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw; rep working; sleep 0.6; rep idle; }
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in $'\r'|$'\n') submit_line ;; *) _buf+=$_ch ;; esac
  read -t 0 || redraw
done
LOOP
fm_backend_herdr_send_text_line "$TARGET" "bash '$STATE/loop.sh' '$SUBMITTED'" || exit 1
sleep 2
{ printf 'composer state before tests: '; fm_backend_composer_state herdr "$TARGET"; echo; } > "$OUT/preflight.txt" 2>&1

# Phase 1: a message larger than one exec argument, through inject_msg.
afk_enter "$STATE"
big=$(head -c 200000 /dev/zero | tr '\0' 'x')
LOG="$OUT/direct-inject.log" FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
  FM_INJECT_CONFIRM_SLEEP=0.5 FM_INJECT_CONFIRM_RETRIES=3 inject_msg "Supervisor escalate: $big" "$STATE"
echo "inject_msg rc=$?" >> "$OUT/direct-inject.log"
cp "$SUBMITTED" "$OUT/direct-submitted.log"
fm_backend_herdr_cli "$SESSION" pane read "$PANE" --source visible --lines 5 > "$OUT/direct-pane.txt" 2>&1
{ printf 'composer state after direct: '; fm_backend_composer_state herdr "$TARGET"; echo; } >> "$OUT/preflight.txt" 2>&1

# Phase 2: the real daemon with a huge start-up catch-all span.
for sm in alpha bravo charlie; do
  : > "$STATE/secondmate-$sm.status"
  for i in $(seq 1 700); do
    printf 'done: secondmate-%s shipped fix %d for the café ledger, PR https://github.com/example/repo/pull/%d merged\n' "$sm" "$i" "$i" >> "$STATE/secondmate-$sm.status"
  done
done
printf 'needs-decision [key=pick-db]: choose Postgres or SQLite for the ledger\n' >> "$STATE/secondmate-charlie.status"
wc -c "$STATE"/*.status > "$OUT/status-sizes.txt"
FM_STATE_OVERRIDE="$STATE" FM_SUPERVISOR_TARGET="$TARGET" FM_SUPERVISOR_BACKEND=herdr \
  FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
  FM_HEARTBEAT_SCAN_SECS=1 FM_CHECK_INTERVAL=999999 FM_INJECT_CONFIRM_SLEEP=0.5 FM_INJECT_CONFIRM_RETRIES=6 \
  FM_STALE_ESCALATE_SECS=999999 FM_MAX_DEFER_SECS=10 FM_WEDGE_ALARM_CHANNEL=off \
  nohup "$DAEMON" > "$STATE/daemon.out" 2> "$STATE/daemon.err" &
DPID=$!
sleep "$RUN_SECS"

cp "$STATE/.supervise-daemon.log" "$OUT/daemon.log" 2>/dev/null
cp "$SUBMITTED" "$OUT/submitted.log"
fm_backend_herdr_cli "$SESSION" pane read "$PANE" --source visible --lines 8 > "$OUT/supervisor-pane.txt" 2>&1
{ printf 'buffer bytes: '; LC_ALL=C wc -c < "$STATE/.subsuper-escalations" 2>/dev/null || echo absent; } > "$OUT/buffer-state.txt"
if [ -d "$STATE/.subsuper-digests" ]; then
  mkdir -p "$OUT/subsuper-digests"; cp "$STATE/.subsuper-digests"/* "$OUT/subsuper-digests/" 2>/dev/null
  ls -l "$STATE/.subsuper-digests" >> "$OUT/buffer-state.txt"
fi
cp "$STATE/.subsuper-inject-wedged" "$OUT/wedge-marker.txt" 2>/dev/null
