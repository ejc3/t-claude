#!/usr/bin/env zsh
# t-claude turns tmux's extended-keys on (off by default in tmux), so claude gets keys as the
# terminal sends them: the kitty keyboard protocol through tmux. A user's own setting other than
# off is left alone. No real tmux server, Claude executable, credentials or home configuration
# is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-extkeys-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
mkdir -p "$test_root/project"
cd "$test_root/project" || exit 1
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }

_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
_tclaude_pane_alive() { [[ -e "$test_root/typed" ]]; }   # the agent runs once it is typed
nosync-wrap() { "$@"; }
stty() { print -r -- 'speed 38400 baud; -icanon'; }   # the new pane's line editor is up
claude() { return 1; }

reset_case() {
  test_extkeys="$1"
  : > "$test_root/tmux"
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
    show-options) [[ "$argv[-1]" == extended-keys ]] && print -r -- "$test_extkeys" ;;
    send-keys) [[ "$argv[-2]" == -- && "$argv[-3]" == -l ]] && : > "$test_root/typed" ;;
    kill-session) fail 'test attempted to kill a tmux session' ;;
  esac
  return 0
}
run_case() { t-claude "$@" </dev/null 2> "$test_root/stderr"; }

# tmux's default: turned on.
reset_case off
check run_case
check grep -qxF 'set-option -s extended-keys on' "$test_root/tmux"

# Already on, or the user's always: left alone.
for v in on always; do
  reset_case "$v"
  check run_case
  check test "$(grep -c 'set-option -s extended-keys' "$test_root/tmux")" = 0
done

rm -rf "$test_root"
print -r -- "ok: $test_checks checks"
