#!/usr/bin/env bash
# r2-agent v1 acceptance test
# Usage: bash test/acceptance-agent-daemon.sh
set -u

R2=${R2:-./binr/radare2/radare2}
TMPDIR="${R2_AGENT_TEST_TMPDIR:-$(mktemp -d /tmp/r2-agent-accept.XXXXXX)}"
SOCK="$TMPDIR/r2-agent.sock"
LOG="$TMPDIR/r2-agent.log"
BG_SOCK="$TMPDIR/bg.sock"
BG_LOG="$TMPDIR/bg.log"
PASS=0
FAIL=0

cleanup() {
if [ -S "$SOCK" ]; then
"$R2" --send quit --socket "$SOCK" >/dev/null 2>&1 || true
fi
if [ -S "$BG_SOCK" ]; then
"$R2" --send quit --socket "$BG_SOCK" >/dev/null 2>&1 || true
fi
rm -rf "$TMPDIR"
}
trap cleanup EXIT

ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1  $2"; FAIL=$((FAIL+1)); }

# Build local LD_LIBRARY_PATH so the freshly built libr_main is used.
LIBDIRS="$(find "$(pwd)/libr" -maxdepth 1 -type d -printf '%p:' | sed 's/:$//')"
export LD_LIBRARY_PATH="$LIBDIRS"

# G1: help shows agent options
if "$R2" --help 2>&1 | grep -q -- '--daemon'; then
ok "G1 help shows --daemon"
else
bad "G1 help" "--daemon missing from r2 --help"
fi

# G2: start foreground daemon and send a simple command
"$R2" --daemon --foreground --socket "$SOCK" --log "$LOG" >/dev/null 2>&1 &
DAEMON_PID=$!
sleep 0.7
if [ -S "$SOCK" ] && [ "$("$R2" --send '?e hello' --socket "$SOCK" 2>/dev/null)" = "hello" ]; then
ok "G2 daemon starts and answers ?e hello"
else
bad "G2 daemon" "socket/hello check failed"
fi

# G2b: background daemon is ready for immediate send
BG_OUT="$("$R2" --daemon --socket "$BG_SOCK" --log "$BG_LOG" 2>&1)"
BG_RC=$?
BG_HELLO="$("$R2" --send '?e bg' --socket "$BG_SOCK" 2>/dev/null)"
if [ "$BG_RC" -eq 0 ] && [ "$BG_HELLO" = "bg" ]; then
ok "G2b background daemon starts and answers immediately"
else
bad "G2b background" "background start/immediate send failed (rc=$BG_RC out=$BG_OUT hello=$BG_HELLO)"
fi
"$R2" --send quit --socket "$BG_SOCK" >/dev/null 2>&1 || true
sleep 0.2

# G3: state persists across clients
"$R2" --send 'open /bin/ls' --socket "$SOCK" >/dev/null 2>&1
AFL="$( "$R2" --send 'afl~main' --socket "$SOCK" 2>/dev/null )"
PDF="$( "$R2" --send 'pdf @ main' --socket "$SOCK" 2>/dev/null )"
STATUS="$( "$R2" --send status --socket "$SOCK" 2>/dev/null )"
if echo "$AFL" | grep -q main && [ -n "$PDF" ] && echo "$STATUS" | grep -q '/bin/ls' && echo "$STATUS" | grep -q 'analyzed: yes'; then
ok "G3 single RCore state persists (open/status/afl/pdf)"
else
bad "G3 state" "open/status/afl/pdf did not show persisted state"
fi

# G4: close keeps daemon alive, quit removes socket
"$R2" --send close --socket "$SOCK" >/dev/null 2>&1
STATUS="$( "$R2" --send status --socket "$SOCK" 2>/dev/null )"
if echo "$STATUS" | grep -q 'file: none' && [ -S "$SOCK" ]; then
ok "G4 close keeps daemon alive"
else
bad "G4 close" "close/status failed"
fi
"$R2" --send quit --socket "$SOCK" >/dev/null 2>&1
sleep 0.3
if [ ! -S "$SOCK" ]; then
ok "G4 quit removes socket"
else
bad "G4 quit" "socket still exists after quit"
fi

# G5: visual blacklist is rejected and logged
"$R2" --daemon --foreground --socket "$SOCK" --log "$LOG" >/dev/null 2>&1 &
DAEMON_PID=$!
sleep 0.7
OUT="$( "$R2" --send 'V' --socket "$SOCK" 2>/dev/null )"
if echo "$OUT" | grep -q 'rejected'; then
ok "G5 visual blacklist rejects V"
else
bad "G5 blacklist" "V was not rejected"
fi
if [ -f "$LOG" ] && grep -q 'cmd: V' "$LOG"; then
ok "G5 daemon log records request"
else
bad "G5 log" "log does not contain request"
fi

# G5b: client-side timeout returns an error and the daemon recovers
TIMEOUT_OUT="$(timeout 3 "$R2" --send '!sleep 2' --socket "$SOCK" --timeout 1 2>/dev/null || true)"
sleep 2.5
RECOVER="$( "$R2" --send '?e recover' --socket "$SOCK" 2>/dev/null )"
if echo "$TIMEOUT_OUT" | grep -q 'timeout waiting' && [ "$RECOVER" = "recover" ]; then
ok "G5b timeout returns error and daemon recovers"
else
bad "G5b timeout" "timeout/recovery check failed (out='$TIMEOUT_OUT' recover='$RECOVER')"
fi
"$R2" --send quit --socket "$SOCK" >/dev/null 2>&1 || true

# G6: original batch mode is unaffected
if "$R2" -q -c '?e ok' /bin/ls 2>/dev/null | grep -q '^ok$'; then
ok "G6 traditional batch mode still works"
else
bad "G6 batch" "r2 -q -c ?e ok /bin/ls failed"
fi

echo
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
