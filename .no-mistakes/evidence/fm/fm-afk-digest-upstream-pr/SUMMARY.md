# Live validation: bounded away-mode digest (issue #4382)

Every run used the real `bin/fm-supervise-daemon.sh` or its real `inject_msg`, with a drawn `❯ ` composer pane that logs each submitted line.
tmux runs used a private `tmux -L` socket.
herdr runs used a throwaway `fm-lab-afkdigest-*` session owned by `bin/fm-herdr-lab.sh` (provision, then teardown rc=0; the default session was untouched).
Three secondmate status logs held about 78 KB of unread `done:` lines each, 236 KB in total, and the start-up catch-all scan buffered 240,347 bytes.

| Scenario | Base d1ce6b6 | Target ae9a182 |
|---|---|---|
| tmux: start-up catch-all digest | `inject failed: submit unconfirmed after 5 retries (verdict=send-failed, text may be in composer)` repeated, 0 bytes submitted, buffer stuck at 240,347 bytes, wedge alarm (`tmux-before/`) | one 6,446-byte line submitted, valid UTF-8, 3 items cut with `[+N bytes]`, names `.subsuper-digests/digest-*`, which is a verbatim copy of the buffer (2,100 `done:` lines plus the needs-decision), buffer cleared (`tmux-after/`) |
| herdr: start-up catch-all digest | same misleading send-failed loop, 0 bytes submitted, wedge alarm (`herdr-before/`) | one 6,447-byte line submitted, full-text file verbatim, buffer cleared (`herdr-after/`) |
| herdr: 200 KB inject_msg | `submit unconfirmed after 3 retries (verdict=send-failed, text may be in composer)` | `inject failed at initial send or Enter delivery (verdict=send-failed, bytes=200058; ...): .../herdr: Argument list too long`, nothing typed, composer still `empty` |
| tmux: 50 KB inject_msg | n/a | `inject failed at initial send or Enter delivery (verdict=send-failed, bytes=50058; ...): command too long`, nothing typed (`tmux-direct-50k/`) |
| tmux: every Enter swallowed | n/a | `inject failed at Enter confirmation: submit unconfirmed after 3 retries (verdict=pending, bytes=4379, ...)`. The full-text file named in the typed composer text still exists after about 20 composer-guard deferrals, only one file was written, and the wedge alarm and marker carry `last delivery failure: deferred: supervisor composer not confirmed-empty (state=pending...)` (`tmux-stages/`) |
