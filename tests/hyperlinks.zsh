#!/usr/bin/env zsh
# Clickable links reach the terminal through t-claude the way they do without it: claude's
# own tmux >= 3.4 check passes in the pane, and the tmux server is told the client can take them.
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-hyperlink-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL FORCE_HYPERLINK TERM_PROGRAM_VERSION
mkdir -p "$test_root/project"
cd "$test_root/project" || exit 1
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
contains() { [[ "$1" == *"$2"* ]]; }

_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
_tclaude_pane_alive() { [[ -e "$test_root/typed" ]]; }   # the agent runs once it is typed
nosync-wrap() { "$@"; }
stty() { print -r -- 'speed 38400 baud; -icanon'; }   # the new pane's line editor is up
claude() { print -r -- "${TERM_PROGRAM_VERSION-unset}" > "$test_root/env"; return 1; }

reset_case() {
  test_sent="" test_features="$1"
  : > "$test_root/tmux"
  : > "$test_root/env"
  rm -f "$test_root/typed"
}

tmux() {
  print -r -- "${(j: :)${(@q)@}}" >> "$test_root/tmux"
  case "$1" in
    has-session) return 0 ;;
    new-window) print -r -- '@1' ;;
    display-message)
      case "$argv[-1]" in
        '#{pane_pid}') print -r -- 12345 ;;
        '#{pane_id} #{pane_pid}') print -r -- '%1 12345' ;;
        '#{pane_tty}') print -r -- /dev/null ;;
        '#{pid}') print -r -- 999 ;;
      esac ;;
    show-options) [[ "$argv[-1]" == terminal-features ]] && print -r -- "${test_features// /$'\n'}" ;;
    # The pane is typed ` . <launch file>`; record what that file runs.
    send-keys) [[ "$argv[-2]" == -- && "$argv[-3]" == -l ]] && { test_sent="$(<"${(Q)${argv[-1]# . }}")"; : > "$test_root/typed"; } ;;
    kill-session) fail 'test attempted to kill a tmux session' ;;
  esac
  return 0
}
run_case() { t-claude "$@" </dev/null 2> "$test_root/stderr"; }

# The launch line hands claude a tmux version its tmux >= 3.4 hyperlink check can parse:
# a patched build's "next-3.8" becomes 3.8, a stock version passes through untouched.
reset_case 'xterm*:clipboard:ccolour:cstyle:focus:title xterm-256color:sync'
check run_case
check contains "$test_sent" 'TERM_PROGRAM_VERSION=${TERM_PROGRAM_VERSION:+${TERM_PROGRAM_VERSION#next-}} nosync-wrap claude '
(TERM_PROGRAM_VERSION=next-3.8; eval "$test_sent")
check test "$(<"$test_root/env")" = 3.8
(TERM_PROGRAM_VERSION=3.5a; eval "$test_sent")
check test "$(<"$test_root/env")" = 3.5a
# A pane shell with nounset does not abort when the variable is unset (zsh and bash).
(setopt nounset; unset TERM_PROGRAM_VERSION; eval "$test_sent") 2>/dev/null
check test "$(<"$test_root/env")" = ''
: > "$test_root/env"
bash -uc "claude() { echo \"\${TERM_PROGRAM_VERSION-unset}\" > ${(q)test_root}/env; }; nosync-wrap() { \"\$@\"; }; unset TERM_PROGRAM_VERSION; ${test_sent}" 2>/dev/null
check test "$(<"$test_root/env")" = ''
# No FORCE_HYPERLINK: claude's tool subprocesses would inherit it.
check test "${test_sent//FORCE_HYPERLINK/}" = "$test_sent"
# ... and a client attaching afterwards gets the hyperlinks feature, without which tmux drops OSC 8.
check grep -qxF 'set-option -sa terminal-features ,xterm\*:hyperlinks' "$test_root/tmux"
check grep -qxF 'set-option -sa terminal-features ,tmux\*:hyperlinks' "$test_root/tmux"
check grep -qxF 'set-option -sa terminal-features ,alacritty\*:hyperlinks' "$test_root/tmux"

# Another terminal's hyperlinks entry does not stand in for xterm's.
reset_case 'screen*:hyperlinks xterm-256color:sync'
check run_case
check grep -qxF 'set-option -sa terminal-features ,xterm\*:hyperlinks' "$test_root/tmux"

# Already granted (by t-claude before, or by the user's tmux.conf): not appended again.
reset_case $'xterm*:clipboard\nxterm-256color:sync\nxterm*:hyperlinks\ntmux*:hyperlinks\nalacritty*:hyperlinks\nfoot*:hyperlinks'
check run_case
check test "$(grep -c 'hyperlinks' "$test_root/tmux")" = 0

rm -rf "$test_root"
print -r -- "ok: $test_checks checks"
