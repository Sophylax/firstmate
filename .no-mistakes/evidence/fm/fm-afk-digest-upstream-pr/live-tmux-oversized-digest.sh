#!/usr/bin/env bash
# Live driver: real fm-supervise-daemon.sh + real watcher child against a
# private tmux server whose supervisor pane runs a drawn "❯ " composer that
# logs every submitted line. Before the daemon starts, three secondmate status
# logs hold a ~65 KB unread span each, so the start-up catch-all scan buffers
# ~195 KB of events (the issue #4382 trigger).
#
# Usage: live-tmux-oversized-digest.sh <firstmate-root> <out-dir> [run-secs]
set -u
ROOT=$1 OUT=$2 RUN_SECS=${3:-25}
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-afk-digest-live-$$"
mkdir -p "$OUT"
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-digest-live.XXXXXX")
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-digest-shim.XXXXXX")
SUBMITTED="$STATE/submitted.log"; : > "$SUBMITTED"
DPID=
cleanup() {
  [ -z "$DPID" ] || { rm -f "$STATE/.afk"; kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$SHIM" "$STATE"
}
trap cleanup EXIT

# shellcheck source=/dev/null
. "$DAEMON"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')
cat > "$STATE/loop.sh" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
stty -echo -icanon min 1 time 0 2>/dev/null
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "${_buf: -150}"; }
submit_line() { printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw; }
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in $'\r'|$'\n') submit_line ;; *) _buf+=$_ch ;; esac
  # Redraw only when input pauses, so a multi-KB literal paste stays fast.
  read -t 0 || redraw
done
LOOP
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "bash '$STATE/loop.sh' '$SUBMITTED'" Enter
sleep 1
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

# Three secondmates, days of unread "done:" appends (multi-byte text included).
for sm in alpha bravo charlie; do
  : > "$STATE/secondmate-$sm.status"
  for i in $(seq 1 700); do
    printf 'done: secondmate-%s shipped fix %d for the café ledger, PR https://github.com/example/repo/pull/%d merged\n' "$sm" "$i" "$i" >> "$STATE/secondmate-$sm.status"
  done
done
printf 'needs-decision [key=pick-db]: choose Postgres or SQLite for the ledger\n' >> "$STATE/secondmate-charlie.status"
wc -c "$STATE"/*.status > "$OUT/status-sizes.txt"

afk_enter "$STATE"
PATH="$SHIM:$PATH" FM_STATE_OVERRIDE="$STATE" FM_SUPERVISOR_TARGET="$PANE" FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
  FM_HEARTBEAT_SCAN_SECS=1 FM_CHECK_INTERVAL=999999 FM_INJECT_CONFIRM_SLEEP=0.5 FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 FM_MAX_DEFER_SECS=10 FM_WEDGE_ALARM_CHANNEL=off \
  nohup "$DAEMON" > "$STATE/daemon.out" 2> "$STATE/daemon.err" &
DPID=$!
sleep "$RUN_SECS"

cp "$STATE/.supervise-daemon.log" "$OUT/daemon.log" 2>/dev/null
cp "$SUBMITTED" "$OUT/submitted.log"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$PANE" > "$OUT/supervisor-pane.txt"
{ printf 'buffer bytes: '; LC_ALL=C wc -c < "$STATE/.subsuper-escalations" 2>/dev/null || echo absent; } > "$OUT/buffer-state.txt"
if [ -d "$STATE/.subsuper-digests" ]; then
  mkdir -p "$OUT/subsuper-digests"
  cp "$STATE/.subsuper-digests"/* "$OUT/subsuper-digests/" 2>/dev/null
  ls -l "$STATE/.subsuper-digests" >> "$OUT/buffer-state.txt"
fi
cp "$STATE/.subsuper-inject-wedged" "$OUT/wedge-marker.txt" 2>/dev/null
printf '%s\n' "$STATE" > "$OUT/state-dir.txt"
