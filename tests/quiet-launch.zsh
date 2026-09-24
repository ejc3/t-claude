#!/usr/bin/env zsh
# A t-claude pane starts the way a bare terminal does: one short prompt line, then claude --
# not the whole launch line wrapped over several rows, twice. See LAUNCH TYPING in t-claude.zsh.
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
if [[ "${1-}" == --tty-case ]]; then
  test_root="$2"
else
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-quiet-tests.XXXXXXXX")" || exit 1
fi
export HOME="$test_root/home" XDG_CACHE_HOME="$test_root/home/.cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
mkdir -p "$HOME" "$test_root/a project"
cd "$test_root/a project" || exit 1
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
contains() { [[ "$1" == *"$2"* ]]; }
count() { print x >> "$test_root/$1"; wc -l < "$test_root/$1" | tr -d ' '; }

_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
_tclaude_evict_window_viewers() { :; }
_tclaude_mint_view() { print -r -- main__tcv__1; }
_tclaude_pane_alive() { [[ -e "$test_root/alive" ]]; }   # the agent runs once it is typed
nosync-wrap() { "$@"; }
# The pane's shell (pid 12345) owns its terminal unless test_fg names another foreground group.
ps() {
  [[ "$1 $2 $3" == "-o tpgid= -p" ]] && { print -r -- "  ${test_fg:-$4}"; return; }
  [[ "$1 $2 $3" == "-o comm= -p" ]] && { print -r -- "${test_shell:-dash}"; return; }
  command ps "$@"
}
claude() { print -rl -- "$PWD" "$@" > "$test_root/argv"; return "${test_rc:-1}"; }
# The pane's line editor comes up on the third look at its tty; the terminal is 40x120.
stty() {
  [[ "$1" == size ]] && { print -r -- '40 120'; return; }
  (( $(count stty) >= 3 )) && print -r -- 'speed 38400 baud; -icanon' || print -r -- 'speed 38400 baud; icanon'
}

reset_case() {
  test_exists=0 test_reuse=0 test_typed="" test_pane="" test_no_start=0 test_fg="" test_shell="" test_panepid=12345
  : > "$test_root/tmux"; : > "$test_root/stty"; rm -f "$test_root/alive"
}
tmux() {
  print -r -- "${(j: :)${(@q)@}}" >> "$test_root/tmux"
  case "$1" in
    has-session) return 0 ;;
    list-windows)
      [[ "$argv[-1]" == '#{window_id} #{@tclaude_key}' ]] && (( test_exists )) && print -r -- "@7 $key"
      # An exited window of this folder under another key: the reuse-by-folder candidate.
      [[ "$argv[-1]" == *'#{@tclaude_path}'* ]] && (( test_reuse )) && print -r -- "@5"$'\t'"old-key"$'\t'"$PWD"$'\t'"claude"
      [[ "$argv[-1]" == *'#{window_index}'* ]] && print -r -- "@7"$'\t'"1" ;;
    attach) return ${TEST_ATTACH_RC:-0} ;;
    new-window) print -r -- '@7' ;;
    display-message)
      case "$argv[-1]" in
        '#{pane_pid}') print -r -- 12345 ;;
        '#{pane_id} #{pane_pid}') print -r -- "%3 $test_panepid" ;;
        '#{pane_tty}') print -r -- /dev/null ;;
        '#{pid}') print -r -- 999 ;;
        '#{@tclaude_agent}') print -r -- claude ;;
        '#{client_session}') print -r -- main__tcv__1 ;;
        '#{client_control_mode}') print -r -- 0 ;;
        '#{client_width} #{client_height}') print -r -- '100 30' ;;
      esac ;;
    send-keys)
      # Every launch types under the server's launch lock.
      zsh -fc 'zmodload zsh/system; zsystem flock -t 0 -f fd "$1"' - "$lockfile" 2>/dev/null && print -r -- typed-unlocked >> "$test_root/violations"
      if [[ "$argv[-2]" == -- && "$argv[-3]" == -l ]]; then
        test_typed="$argv[-1]" test_pane="$argv[-4]"
        print -r -- "$test_typed" > "$test_root/typed"
        wc -l < "$test_root/stty" | tr -d ' ' > "$test_root/typed-at"
      elif [[ "$argv[-1]" == Enter ]] && (( ! test_no_start )); then
        : > "$test_root/alive"
      fi ;;
    kill-session) fail 'test attempted to kill a tmux session' ;;
  esac
  return 0
}
file_of() { print -r -- "${(Q)${1# . }}"; }
mkdir -p -m 700 "$TMUX_TMPDIR/tmux-$UID"
lockfile="${TMUX_TMPDIR:A}/tmux-$UID/default.tclaude-launch.lock"
lock_free() { zsh -fc 'zmodload zsh/system; zsystem flock -t 0 -f fd "$1"' - "$lockfile" 2>/dev/null; }

# With a terminal (run under zpty below): the new window is sized to it BEFORE the line is
# typed, and handed back to automatic sizing after, so attaching reflows nothing.
if [[ "${1-}" == --tty-case ]]; then
  [ -t 0 ] || fail 'no tty'
  reset_case
  case "${3-}" in
    attach-fail) TEST_ATTACH_RC=1 ;;
    # Inside tmux, on one of this session's views, re-showing an existing window: nothing to
    # unpin, and t-claude must still succeed.
    intmux) export TMUX="$TMUX_TMPDIR/tmux-$UID/default,1,0" TMUX_PANE=%9 TCLAUDE_ADOPT_PANE=0; test_exists=1; : > "$test_root/alive" ;;
  esac
  t-claude --resume tty-id 2> "$test_root/tty-stderr"
  print -r -- $? > "$test_root/tty-rc"
  print -r -- done > "$test_root/tty-done"
  exit 0
fi

# NEW WINDOW. One short line, space-prefixed (HIST_IGNORE_SPACE), to the pane itself ...
reset_case
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test "$test_pane" = %3
[[ "$test_typed" =~ "^ \\. $HOME/\\.cache/t-claude/launch/launch\\.[A-Za-z0-9]+\$" ]] || fail "typed: $test_typed"
# ... typed only once the line editor was up, so the tty never echoed it raw first.
check test "$(<"$test_root/typed-at")" = 3
check test "$(ls -ld "$HOME/.cache/t-claude/launch" | cut -c1-10)" = drwx------
launch_file="$(file_of "$test_typed")"
check contains "$(<"$launch_file")" 'nosync-wrap claude --resume some-id '
# Typed under the server's launch lock (the stub checks), and the lock is free again after.
check test ! -e "$test_root/violations"
check lock_free
# Sourcing it is the launch: cd, then claude -- and the file removes itself.
cp "$launch_file" "$test_root/launch-copy"
cd "$HOME" || fail cd
( . "$launch_file" )
check test ! -e "$launch_file"
check test "$(head -1 "$test_root/argv")" = "$test_root/a project"
check contains "$(<"$test_root/argv")" 'some-id'
# `exit` in the sourced file still ends the window's shell on a clean /exit ...
cp "$test_root/launch-copy" "$launch_file"
zsh -fc "nosync-wrap() { \"\$@\" }; claude() { return 0 }; . ${(q)launch_file}; print -r -- survived" > "$test_root/out"
check test ! -s "$test_root/out"
# ... and keeps it for a claude that refused to start, so the error stays readable.
cp "$test_root/launch-copy" "$launch_file"
zsh -fc "nosync-wrap() { \"\$@\" }; claude() { return 1 }; . ${(q)launch_file}; print -r -- survived" > "$test_root/out"
check test "$(<"$test_root/out")" = survived
cd "$test_root/a project" || fail cd

# RELAUNCH into an exited agent's window: to the checked pane, at once -- its shell is at a
# prompt already, so there is no editor wait (no pane_tty query at all).
reset_case
test_exists=1
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check grep -qxF "send-keys -R -t %3 ''" "$test_root/tmux"
check grep -qxF 'send-keys -t %3 C-u' "$test_root/tmux"
check test "$test_pane" = %3
# (the shell is at its prompt: the one look at its tty says so, and it is typed at once)
check test "$(wc -l < "$test_root/stty" | tr -d ' ')" -le 3
check contains "$(<"$test_root/stderr")" relaunched

# A claude that refuses to start (its shell sourced the file and is back at the prompt) does
# not hold the window's lock for the full 3s wait.
reset_case
test_exists=1 test_no_start=1
stty() { print -r -- 'speed 38400 baud; -icanon'; }
functions[_tq_tmux]="$functions[tmux]"
tmux() { _tq_tmux "$@"; [[ "$1 $argv[-1]" == 'send-keys Enter' ]] && rm -f "$(file_of "$test_typed")"; return 0; }
zmodload zsh/datetime; t0=$EPOCHREALTIME
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
(( EPOCHREALTIME - t0 < 1.5 )) || fail "a failed start held the launch for $(( EPOCHREALTIME - t0 ))s"
functions[tmux]="$functions[_tq_tmux]"

# ... but not while its agent is running.
reset_case
test_exists=1; : > "$test_root/alive"
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test -z "$test_typed"

# SERIALISED: another launch holds the server's lock. This one waits for it and then sees that
# launch's agent running, so it types nothing (without the lock both would have typed).
# Another process holding the server's lock for $1 seconds, in the background ($! is it).
hold_lock() {
  rm -f "$test_root/held"
  zsh -fc 'zmodload zsh/system; zsystem flock -f fd "$1" && { : > "$2"; sleep "$3"; }' - "$lockfile" "$test_root/held" "$1" &
  local n=0; until [[ -e "$test_root/held" ]] || (( n++ > 100 )); do sleep 0.02; done
}
reset_case
test_exists=1
hold_lock 0.6
( sleep 0.3; : > "$test_root/alive" ) &   # that launch's agent is up by the time it lets go
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
wait
check test -z "$test_typed"
# A holder that dies (kill -9, no cleanup) releases it at once: nothing stale to break.
reset_case
test_exists=1
hold_lock 60; holder=$!
kill -9 $holder; wait $holder 2>/dev/null
check lock_free
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test "$test_pane" = %3
# A waiter that runs out of time launches NOTHING -- it does not go ahead unlocked.
reset_case
test_exists=1
hold_lock 4; holder=$!
_tclaude_lock_wait=1 t-claude --resume some-id </dev/null 2> "$test_root/stderr" && fail 'launched without the lock'
check test -z "$test_typed"
check contains "$(<"$test_root/stderr")" 'nothing was launched'
kill $holder 2>/dev/null; wait $holder 2>/dev/null
# No lock to be had (its directory unwritable): nothing is launched, rather than unlocked.
reset_case
test_exists=1
rm -f "$lockfile"; chmod 500 "${lockfile:h}"
t-claude --resume some-id </dev/null 2> "$test_root/stderr" && fail 'launched without a lock'
chmod 700 "${lockfile:h}"
check test -z "$test_typed"
# One lock per server whoever asks: through a symlinked TMUX_TMPDIR (macOS /tmp) it is the
# same file as the resolved path $TMUX carries inside tmux.
ln -s "$TMUX_TMPDIR" "$test_root/tmux-link"
( TMUX_TMPDIR="$test_root/tmux-link"; _tclaude_launch_lock && { : > "$test_root/held"; sleep 3; } ) &
n=0; until [[ -e "$test_root/held" ]] || (( n++ > 100 )); do sleep 0.02; done
( TMUX="${TMUX_TMPDIR:A}/tmux-$UID/default,1,0" _tclaude_lock_wait=1; _tclaude_launch_lock ) 2>/dev/null && fail 'two locks for one server'
wait
# A socket in a directory that is not ours alone (tmux -S /tmp/x) keeps its lock in our own
# cache, not beside the socket where anyone could plant or swap it.
mkdir -p "$test_root/shared"; chmod 1777 "$test_root/shared"
( TMUX="$test_root/shared/sock,1,0"; _tclaude_launch_lock; print -r -- "$(ls "$test_root/shared")" > "$test_root/shared-ls"; ls "$HOME/.cache/t-claude/locks" > "$test_root/own-ls" )
check test -z "$(<"$test_root/shared-ls")"
check test -n "$(<"$test_root/own-ls")"

# RELAUNCH only into a shell that owns its terminal: not into a foreground program, raw-mode
# (less, vim: -icanon like a prompt) or not (a build, sleep).
reset_case
test_exists=1 test_fg=999
stty() { print -r -- 'speed 38400 baud; -icanon'; }
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test -z "$test_typed"
check contains "$(<"$test_root/stderr")" 'not relaunching'
# A shell with no line editor (dash: canonical at its prompt) is still at its prompt ...
reset_case
test_exists=1
stty() { print -r -- 'speed 38400 baud; icanon'; }
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test "$test_pane" = %3
# ... but a zsh or bash that owns its terminal in canonical mode is waiting in `read` (or
# running a function): not at its prompt.
reset_case
test_exists=1 test_shell=zsh
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test -z "$test_typed"
check contains "$(<"$test_root/stderr")" 'not relaunching'
reset_case
test_exists=1 test_shell=-bash
stty() { print -r -- 'speed 38400 baud; -icanon'; }
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test "$test_pane" = %3
# An agent that comes up while the relaunch waits for the prompt is attached to, not typed into.
reset_case
test_exists=1 test_fg=999
( sleep 0.3; : > "$test_root/alive" ) &
functions[_tq_ps]="$functions[ps]"
ps() { [[ -e "$test_root/alive" ]] && test_fg=""; _tq_ps "$@"; }
check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
wait
functions[ps]="$functions[_tq_ps]"
check test -z "$test_typed"
check test -z "$(grep -c relaunched "$test_root/stderr" | grep -v '^0$')"
# The caller's OWN pane -- this very process is its shell -- is typed at once (the shell runs
# the line when t-claude returns), without resetting it or waiting for an agent.
zmodload zsh/system
reset_case
test_exists=1 test_fg=999 test_panepid=$sysparams[pid]
TMUX="$TMUX_TMPDIR/tmux-$UID/default,1,0" TMUX_PANE=%3 TCLAUDE_ADOPT_PANE=0 check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test "$test_pane" = %3
check test "$(grep -c 'send-keys -R' "$test_root/tmux")" = 0
# A background job or script started FROM that pane is not its shell: whatever runs in the
# foreground there (vim) must not get the line.
reset_case
test_exists=1 test_fg=999
TMUX="$TMUX_TMPDIR/tmux-$UID/default,1,0" TMUX_PANE=%3 TCLAUDE_ADOPT_PANE=0 check t-claude --resume some-id </dev/null 2> "$test_root/stderr"
check test -z "$test_typed"

# REUSE BY FOLDER skips a window whose shell is running something: it keeps its key and saved
# inference, and a new window is made instead.
reset_case
test_reuse=1 test_fg=999
check t-claude --resume other-id </dev/null 2> "$test_root/stderr"
check test "$(grep -c 'set-option -w -t @5 @tclaude_key' "$test_root/tmux")" = 0
check grep -q '^new-window' "$test_root/tmux"
check test "$test_pane" = %3
# ... and re-keys one whose shell is at its prompt.
reset_case
test_reuse=1
check t-claude --resume other-id </dev/null 2> "$test_root/stderr"
check grep -q 'set-option -w -t @5 @tclaude_key' "$test_root/tmux"

# A pane that is gone is never typed into: an empty target is tmux's CURRENT pane.
reset_case
_tclaude_type "" ' cd -- /x' "$HOME/.cache/t-claude" && fail 'typed into an empty target'
check test "$(grep -c send-keys "$test_root/tmux")" = 0

# A cache path with a space, `#` and `!`: single-quoted, so neither the shell nor history
# expansion (bash -H, interactive zsh) touches it.
reset_case
_tclaude_type %3 ' echo sourced > '"${(q)test_root}"'/odd' "$test_root/c #W x!y"
check contains "$test_typed" "'"
bash -c "set -H; eval ${(qq)test_typed}"; check test "$(<"$test_root/odd")" = sourced
check test ! -e "$(file_of "$test_typed")"

# No usable cache directory: the whole line is typed, as before.
reset_case
: > "$test_root/not-a-dir"
_tclaude_type %3 ' cd -- /x && { claude; }' "$test_root/not-a-dir"
check test "$test_typed" = ' cd -- /x && { claude; }'

# WITH A TERMINAL (zpty gives the case a tty): sized to 120x40 before typing, then unpinned.
zmodload zsh/zpty
zpty -b ttycase "zsh -f ${(q)local_repo}/tests/quiet-launch.zsh --tty-case ${(q)test_root}"
n=0; while [[ ! -e "$test_root/tty-done" ]] && (( n++ < 100 )); do sleep 0.1; done
zpty -d ttycase
check test -e "$test_root/tty-done"
log="$(<"$test_root/tmux")"
check contains "$log" 'resize-window -t @7 -x 120 -y 40'
r=$(grep -n 'resize-window' "$test_root/tmux" | cut -d: -f1)
t=$(grep -n 'send-keys -t %3 -l' "$test_root/tmux" | cut -d: -f1)
a=$(grep -n '^attach' "$test_root/tmux" | cut -d: -f1)
check test -n "$r" -a -n "$t" -a -n "$a"
(( r < t && t < a )) || fail "order resize=$r type=$t attach=$a"
# Unpinned by the attach command itself, after the client is attached -- not before, when the
# window would be re-sized to some other client of the session.
check test "$(grep 'set-option' "$test_root/tmux" | grep -c 'window-size')" = 1
check contains "$(grep '^attach' "$test_root/tmux")" "\; set-option -wu -t @7 window-size"
check test "$(<"$test_root/tty-rc")" = 0

# A failed attach (unknown $TERM, a view gone) skips the rest of that tmux command: the window
# is unpinned anyway, not left at a fixed size.
rm -f "$test_root/tty-done"
zpty -b ttycase "zsh -f ${(q)local_repo}/tests/quiet-launch.zsh --tty-case ${(q)test_root} attach-fail"
n=0; while [[ ! -e "$test_root/tty-done" ]] && (( n++ < 100 )); do sleep 0.1; done
zpty -d ttycase
check test "$(<"$test_root/tty-rc")" = 1
check test "$(tail -1 "$test_root/tmux")" = 'set-option -wu -t @7 window-size'
# Inside tmux, re-showing an existing window (nothing to unpin): t-claude succeeds.
rm -f "$test_root/tty-done"
zpty -b ttycase "zsh -f ${(q)local_repo}/tests/quiet-launch.zsh --tty-case ${(q)test_root} intmux"
n=0; while [[ ! -e "$test_root/tty-done" ]] && (( n++ < 100 )); do sleep 0.1; done
zpty -d ttycase
check test "$(<"$test_root/tty-rc")" = 0

rm -rf "$test_root"
print -r -- "ok: $test_checks checks"
