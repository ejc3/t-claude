#!/usr/bin/env zsh
# t-claude --restart, and a launch waiting out a server mid-exit, against REAL tmux servers on
# a private socket directory -- including a client stuck writing to a terminal nobody reads,
# the case where a plain kill-server left launches failing with "server exited unexpectedly".
# Needs tmux and python3 (for the unread pty). Never touches the user's own tmux server.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
real_tmux="${TCLAUDE_TMUX:-}"
for c in "$real_tmux" "$HOME/.local/bin/tmux-scroll" /usr/local/bin/tmux-scroll "${commands[tmux]-}"; do
  [[ -n "$c" && -x "$c" ]] && { real_tmux="$c"; break; }
done
[[ -x "$real_tmux" ]] || { print -u2 "FAIL: no tmux to test with"; exit 1; }
(( $+commands[python3] )) || { print -u2 "FAIL: python3 is needed for the unread terminal"; exit 1; }
source "$local_repo/t-claude.zsh" || exit 1

# Short: a unix socket path must fit in ~107 bytes.
test_root="$(mktemp -d /tmp/tcr.XXXXXX)" || exit 1
export HOME="$test_root/h" XDG_CACHE_HOME="$test_root/h/.cache" XDG_STATE_HOME="$test_root/h/.state" \
  TMUX_TMPDIR="$test_root/t" CLAUDE_CONFIG_DIR="$test_root/claude"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
mkdir -p "$HOME" "$TMUX_TMPDIR" "$XDG_CACHE_HOME/t-claude/bin" "$CLAUDE_CONFIG_DIR/sessions" "$test_root/a project"
ln -s "$real_tmux" "$XDG_CACHE_HOME/t-claude/bin/tmux"
export PATH="$XDG_CACHE_HOME/t-claude/bin:$PATH"
rec="$XDG_STATE_HOME/t-claude/restart.txt"
typeset -a started
test_checks=0

cleanup() {
  local p
  for p in $started; do kill -KILL "$p" 2>/dev/null; done
  command tmux kill-server 2>/dev/null
  rm -rf "$test_root"
}
trap cleanup EXIT
fail() { print -u2 -r -- "FAIL: $*"; print -u2 -r -- "--- restart.txt:"; cat "$rec" >&2 2>/dev/null; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
alive() { kill -0 "$1" 2>/dev/null; }
dead() { [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != [^Z]* ]]; }   # gone, or a zombie
is() { [[ "$1" == "$2" ]]; }
has() { [[ "$1" == *"$2"* ]]; }
at_most() { (( $1 <= $2 )); }
# The recorded line for UUID, run with a stub t-claude: prints "<its PWD>|<its arguments>".
resumes() {
  local line
  line="$(grep -F -- "--resume $1" "$rec" | tail -1)" || return 1
  (t-claude() { print -r -- "$PWD|$*"; }; eval "${line## #}")
}

# A server whose one window floods its pane, so an attached client always has output to write.
start_server() {
  command tmux new-session -d -s "${1:-main}" -c "$test_root/a project" 'yes' || fail "could not start a test server"
  spid="$(command tmux display-message -p '#{pid}')"
  started+=("$spid")
}
keyed() {   # WINDOW UUID [FOLDER] -- make it look like a t-claude window
  command tmux set-option -w -t "$1" @tclaude_key "k$RANDOM"
  command tmux set-option -w -t "$1" @tclaude_path "${3:-$test_root/a project}"
  command tmux set-option -w -t "$1" @tclaude_resume "$2"
}

# A client attached on a pty whose master is never read: its tty fills and it blocks in write.
stuck_client() {
  rm -f "$test_root/cpid"
  python3 - "$real_tmux" "$test_root/cpid" "${1:-main}" >/dev/null 2>&1 <<'PY' &
import os, pty, subprocess, sys, time
m, s = pty.openpty()
p = subprocess.Popen([sys.argv[1], "attach", "-t", sys.argv[3]], stdin=s, stdout=s, stderr=s,
                     env=dict(os.environ, TERM="xterm-256color"), start_new_session=True)
os.close(s)
open(sys.argv[2], "w").write(str(p.pid))
time.sleep(600)   # holds the master open, never reads it
PY
  started+=("$!")
  local i
  for i in {1..50}; do [[ -s "$test_root/cpid" ]] && break; sleep 0.1; done
  client="$(<"$test_root/cpid")"
  started+=("$client")
  sleep 2
  alive "$client" || fail "the stuck client did not stay up"
}
server_gone() { command tmux kill-server 2>/dev/null; sleep 0.3; }

u1=11111111-2222-3333-4444-555555555555
u2=22222222-3333-4444-5555-666666666666
u3=33333333-4444-5555-6666-777777777777
u4=44444444-5555-6666-7777-888888888888

# 1. No server: nothing to stop, and it says what the next launch will run.
out="$(t-claude --restart --yes 2>&1)"
check is $? 0
check has "$out" "no tmux server on"

# 2. Not a terminal and no --yes: refuses, the server stays up.
start_server
out="$(t-claude --restart 2>&1 </dev/null)"
check is $? 1
check has "$out" "pass --yes"
check alive "$spid"

# 3. From a bare terminal with a t-claude window and a stuck client: records the resume line
#    (a folder with a space), SIGKILLs the stuck client, and a new server starts at once.
keyed main:0 "$u1"
stuck_client
t0=$SECONDS
out="$(t-claude --restart --yes 2>&1)"
check is $? 0
check at_most $(( SECONDS - t0 )) 15
check dead "$spid"
check dead "$client"
check grep -q " READY: server $spid is gone" "$rec"
check grep -q "killed stuck client $client of server $spid" "$rec"
check is "$(resumes "$u1")" "$test_root/a project|--resume $u1"
check command tmux new-session -d -s after 'sleep 30'
server_gone

# 4. The same without a UTF-8 locale (tmux then turns tabs and non-ASCII in its output into
#    "_"), a folder holding a tab, a non-ASCII session name, and a window only a view session
#    still shows.
mkdir -p "$test_root/tab"$'\t'"dir"
LANG=C.UTF-8 start_server sølo
LANG=C.UTF-8 keyed sølo:0 "$u2" "$test_root/tab"$'\t'"dir"
LANG=C.UTF-8 command tmux new-session -d -t sølo -s sølo__tcv__77
LANG=C.UTF-8 command tmux kill-session -t sølo
out="$(unset LANG LC_ALL LC_CTYPE; t-claude --restart --yes 2>&1)"
check is $? 0
check is "$(resumes "$u2")" "$test_root/tab"$'\t'"dir|sølo --resume $u2"
check is "$(resumes "$u1")" "$test_root/a project|--resume $u1"   # appended, not truncated
server_gone

# 5. @tclaude_resume blank (a plain re-attach blanks it): the live id comes from claude's own
#    per-process record of the pane's process.
start_server
keyed main:0 ""
ppid="$(command tmux display-message -p -t main:0 '#{pane_pid}')"
print -r -- "{\"pid\":$ppid,\"sessionId\":\"$u3\",\"cwd\":\"x\"}" > "$CLAUDE_CONFIG_DIR/sessions/$ppid.json"
out="$(t-claude --restart --yes 2>&1)"
check is $? 0
check is "$(resumes "$u3")" "$test_root/a project|--resume $u3"
server_gone

# 6. A server already exiting (someone ran kill-server) with a stuck client: waits for it to
#    go, then SIGKILLs the client it left blocked.
start_server
stuck_client
kill -TERM "$spid"
out="$(t-claude --restart --yes 2>&1)"
check is $? 0
check has "$out" "it has exited"
check dead "$spid"
check dead "$client"

# 7. A launch while the old server is mid-exit waits for it instead of failing.
start_server
stuck_client
kill -TERM "$spid"
sleep 0.3
check has "$(command tmux display-message -p x 2>&1)" "server exited unexpectedly"
out="$(_tclaude_await_server_exit 2>&1)"
check is $? 0
check has "$out" "does not answer; waiting"
check dead "$spid"
check command tmux new-session -d -s after 'sleep 30'
kill -KILL "$client" 2>/dev/null
server_gone

# 8. A LIVE server this client cannot talk to (a client older than the server prints the same
#    "server exited unexpectedly"): never stopped without a yes, and never called exiting.
start_server
# An executable, not a function: t-claude runs some tmux calls under timeout(1).
mkdir -p "$test_root/old"
print -rl -- '#!/bin/sh' \
  'case "$1" in display-message) echo "server exited unexpectedly" >&2; exit 1 ;; esac' \
  "exec ${(q)real_tmux} \"\$@\"" > "$test_root/old/tmux"
chmod +x "$test_root/old/tmux"
saved_path="$PATH"; PATH="$test_root/old:$PATH"; rehash
_tclaude_exit_wait=2
out="$(t-claude --restart 2>&1 </dev/null)"
check is $? 1
check has "$out" "does not answer this tmux client"
check alive "$spid"
out="$(_tclaude_await_server_exit 2>&1)"
check is $? 1
check has "$out" "does not answer this tmux client"
out="$(t-claude --restart --yes 2>&1 </dev/null)"
check is $? 0
check dead "$spid"
PATH="$saved_path"; rehash
_tclaude_exit_wait=25

# 9. The record cannot be written: nothing stops.
start_server
: > "$test_root/a-file"
out="$(XDG_STATE_HOME="$test_root/a-file" t-claude --restart --yes 2>&1)"
check is $? 1
check has "$out" "nothing stopped"
check alive "$spid"

# 10. A second restart while the first is still stopping keeps the first one's lines.
keyed main:0 "$u4"
stuck_client
sock="${TMUX_TMPDIR}/tmux-$UID/default"
out="$(TMUX="$sock,$spid,0" t-claude --restart --yes 2>&1)"   # from inside: returns at once
check is $? 0
check has "$out" "run t-claude again"
out="$(t-claude --restart --yes 2>&1)"
for i in {1..150}; do grep -q " READY: server $spid" "$rec" && break; sleep 0.1; done
check grep -q " READY: server $spid is gone" "$rec"
check is "$(resumes "$u4")" "$test_root/a project|--resume $u4"
check dead "$spid"
check dead "$client"

# 11. A stopped (wedged) server: the pid query is bounded even though the tmux client hands its
#     stdout to the server; without a yes nothing stops, with one the server is SIGKILLed.
start_server
kill -STOP "$spid"
_tclaude_exit_wait=2
t0=$SECONDS
out="$(t-claude --restart 2>&1 </dev/null)"
check is $? 1
check at_most $(( SECONDS - t0 )) 15
check has "$out" "It is stopped"
check alive "$spid"
out="$(t-claude --restart --yes 2>&1 </dev/null)"
check is $? 0
check dead "$spid"
check grep -q " READY: server $spid is gone" "$rec"
_tclaude_exit_wait=25

print -r -- "restart: $test_checks checks passed"
