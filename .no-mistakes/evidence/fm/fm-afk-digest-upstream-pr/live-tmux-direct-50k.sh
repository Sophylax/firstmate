#!/usr/bin/env bash
# Live failure-stage driver on a private tmux server (real tmux binary).
# Phase 1 (direct): inject_msg with a 200,000-byte message, so real tmux
#   refuses the literal send ("command too long").
# Phase 2 (daemon): the real daemon delivers a bounded digest while a PATH shim
#   drops every Enter the daemon sends, so the digest is typed but never
#   submitted. Expect: an Enter-confirmation log line, the named full-text file
#   still on disk, no extra full-text files on later retries, and a wedge
#   alarm that names the last delivery failure.
#
# Usage: live-tmux-failure-stages.sh <firstmate-root> <out-dir> [run-secs]
set -u
ROOT=$1 OUT=$2 RUN_SECS=${3:-90}
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-afk-stage-live-$$"
mkdir -p "$OUT"
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stage-live.XXXXXX")
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stage-shim.XXXXXX")
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
  read -t 0 || redraw
done
LOOP
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "bash '$STATE/loop.sh' '$SUBMITTED'" Enter
sleep 1
# Shim: private socket; while $STATE/.swallow exists, drop every Enter key.
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ] && [ -f "$STATE/.swallow" ]; then
  a=(); for x in "\$@"; do [ "\$x" = Enter ] || a+=("\$x"); done
  [ "\${#a[@]}" -gt 3 ] || [ "\${a[*]}" != "send-keys -t $PANE" ] || exit 0
  exec "$REAL_TMUX" -L "$SOCKET" "\${a[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

afk_enter "$STATE"
big=$(head -c 50000 /dev/zero | tr '\0' 'x')
PATH="$SHIM:$PATH" LOG="$OUT/direct-inject.log" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$PANE" \
  FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=3 inject_msg "Supervisor escalate: $big" "$STATE"
echo "inject_msg rc=$?" >> "$OUT/direct-inject.log"
cp "$SUBMITTED" "$OUT/direct-submitted.log"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$PANE" > "$OUT/direct-pane.txt"

exit 0
for sm in alpha bravo; do
  : > "$STATE/secondmate-$sm.status"
  for i in $(seq 1 150); do
    printf 'done: secondmate-%s shipped fix %d, PR https://github.com/example/repo/pull/%d merged\n' "$sm" "$i" "$i" >> "$STATE/secondmate-$sm.status"
  done
done
PATH="$SHIM:$PATH" FM_STATE_OVERRIDE="$STATE" FM_SUPERVISOR_TARGET="$PANE" FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
  FM_HEARTBEAT_SCAN_SECS=1 FM_CHECK_INTERVAL=999999 FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=3 \
  FM_STALE_ESCALATE_SECS=999999 FM_MAX_DEFER_SECS=15 FM_WEDGE_ALARM_CHANNEL=off \
  nohup "$DAEMON" > "$STATE/daemon.out" 2> "$STATE/daemon.err" &
DPID=$!
sleep "$RUN_SECS"
cp "$STATE/.supervise-daemon.log" "$OUT/daemon.log" 2>/dev/null
cp "$SUBMITTED" "$OUT/submitted.log"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -J -S - -t "$PANE" > "$OUT/supervisor-pane.txt"
{ printf 'buffer bytes: '; LC_ALL=C wc -c < "$STATE/.subsuper-escalations" 2>/dev/null || echo absent
  ls -l "$STATE/.subsuper-digests" 2>&1; } > "$OUT/buffer-state.txt"
mkdir -p "$OUT/subsuper-digests"; cp "$STATE/.subsuper-digests"/* "$OUT/subsuper-digests/" 2>/dev/null
cp "$STATE/.subsuper-inject-wedged" "$OUT/wedge-marker.txt" 2>/dev/null
