#!/usr/bin/env zsh
# Fake launcher plus a private tmux server for the generated hooks. No real
# Claude process, credentials, or existing tmux server is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "${TCLAUDE_TEST_IMPL:-$local_repo/t-claude.zsh}" || exit 1
root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-auto-rc.XXXXXXXX")" || exit 1
socket="$root/hook.sock"
trap 'command tmux -S "$socket" kill-server 2>/dev/null; rm -rf -- "$root"' EXIT
export HOME="$root/home" XDG_CACHE_HOME="$root/cache" TMUX_TMPDIR="$root/tmux-tmp"
export CLAUDE_CONFIG_DIR="$root/claude"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL TCLAUDE_RC_GATE
mkdir -p "$HOME" "$root/a project"
cd "$root/a project" || exit 1
checks=0
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }
check() { (( checks++ )); "$@" || fail "$*"; }
contains() { [[ "$1" == *"$2"* ]]; }

_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
_tclaude_pane_alive() { (( live )); }
_tclaude_shell_at_prompt() { :; }
_tclaude_await_editor() { :; }
_tclaude_await_agent() { :; }
typeset -A opts
exists=0 live=0 recorded_line="" stamp_at_type=""
tmux() {
  case "$1" in
    has-session) return 0 ;;
    list-windows)
      [[ "$argv[-1]" == '#{window_id} #{@tclaude_key}' ]] && (( exists )) && print -r -- "@1 $key" ;;
    new-window) exists=1; print -r -- '@1' ;;
    display-message)
      case "$argv[-1]" in
        '#{pid}') print -r -- 999 ;;
        '#{pane_id} #{pane_pid}') print -r -- '%1 12345' ;;
        '#{@tclaude_agent}') print -r -- claude ;;
      esac ;;
    set-option)
      if [[ "$2" == -wuq && "$argv[-1]" == @tclaude_auto_rc* ]]; then
        unset "opts[$argv[-1]]"
      elif [[ "$2" == -w && "$argv[-2]" == @tclaude_auto_rc* ]]; then
        opts[$argv[-2]]="$argv[-1]"
      fi ;;
    send-keys)
      if [[ "$argv[-2]" == -- && "$argv[-3]" == -l ]]; then
        recorded_line="$(<"${(Q)${argv[-1]# . }}")"
        stamp_at_type="${opts[@tclaude_auto_rc]-}"
      elif [[ "$argv[-1]" == Enter ]]; then
        live=1
      fi ;;
    kill-session|kill-server) fail 'test attempted to stop a real server' ;;
  esac
  return 0
}
launch() { t-claude "$@" </dev/null 2>"$root/stderr"; }

check launch --auto --remote-control
exists=1
first="${opts[@tclaude_auto_rc]-}"
check _tclaude_is_uuid "$first"
check test "$stamp_at_type" = "$first"
check contains "$recorded_line" "TCLAUDE_AUTO_RC_ID=$first "
[[ "${opts[@tclaude_auto_rc_started]-}" == <1-> ]] || fail 'missing Unix launch time'
check test -z "${opts[@tclaude_auto_rc_sid]-}"
opts[@tclaude_auto_rc_used]=1
check launch --auto --remote-control
check test "${opts[@tclaude_auto_rc]-}" = "$first"
check test "${opts[@tclaude_auto_rc_used]-}" = 1
check launch --remote-control
check test -z "${opts[@tclaude_auto_rc]-}"
check test -z "${opts[@tclaude_auto_rc_used]-}"

live=0
check launch --auto --remote-control
second="${opts[@tclaude_auto_rc]-}"
check _tclaude_is_uuid "$second"
check test "$second" != "$first"
live=0
check launch --auto --remote-control --resume 01234567-89ab-cdef-0123-456789abcdef
check test -z "${opts[@tclaude_auto_rc]-}"
live=0
check launch --auto --remote-control --agent-cmd 'true'
check test -z "${opts[@tclaude_auto_rc]-}"
live=0
check launch --auto --remote-control --settings "$root/custom.json"
check test -z "${opts[@tclaude_auto_rc]-}"

# The gate runs while the launch lock is held and refuses even a new window.
lockfile="$TMUX_TMPDIR/tmux-$UID/default.tclaude-launch.lock"
cat > "$root/gate" <<'GATE'
#!/usr/bin/env python3
import fcntl
import os
import sys
assert sys.argv[1:] == ["--check-claude-rc", os.environ["TEST_RC_FOLDER"]]
with open(os.environ["TEST_RC_LOCK"], "r+") as lock:
    try:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        with open(os.environ["TEST_RC_RECEIPT"], "w") as receipt:
            receipt.write("refused under launch lock")
sys.exit(1)
GATE
chmod 700 "$root/gate"
exists=0 live=0 recorded_line=""
if TCLAUDE_RC_GATE="$root/gate" TEST_RC_FOLDER="${PWD:A}" TEST_RC_LOCK="$lockfile" \
   TEST_RC_RECEIPT="$root/gate-result" launch --auto --remote-control; then
  fail 'gate refusal was ignored'
fi
check test "$(cat "$root/gate-result")" = 'refused under launch lock'
check test "$exists" = 0
check test -z "$recorded_line"

# Use a real tmux command queue for the conditional latch. Exercise the exact
# generated hook, including JSON whitespace and a path containing a quote.
check command tmux -S "$socket" -f /dev/null new-session -d -s example
pane="$(command tmux -S "$socket" display-message -p -t example '#{pane_id}')"
hook="$XDG_CACHE_HOME/t-claude/session-sync-auto-rc-v1.sh"
sid=01234567-89ab-cdef-0123-456789abcdef
transcript="$root/a project/with\"quote/$sid.jsonl"
tmux_option() { command tmux -S "$socket" display-message -p -t "$pane" "#{@$1}"; }
expect_option() { [[ "$(tmux_option "$1")" == "$2" ]]; }
invoke() {
  TMUX="$socket,1,0" TMUX_PANE="$pane" TCLAUDE_AUTO_RC_ID="$1" TCLAUDE_AUTO_RC_LOCK="$lockfile" \
    timeout 4 "$hook" "$2"
}
check command tmux -S "$socket" set-option -w -t "$pane" @tclaude_auto_rc "$second"
check command tmux -S "$socket" set-option -w -t "$pane" @tclaude_key example
python3 -c 'import json,sys; print(json.dumps(dict(hook_event_name="SessionStart", session_id=sys.argv[1], transcript_path=sys.argv[2], source="startup"), indent=2))' \
  "$sid" "$transcript" | invoke "$second" start || fail 'SessionStart hook'
check expect_option tclaude_auto_rc_sid "$sid"
check expect_option tclaude_auto_rc_transcript "$transcript"
check expect_option tclaude_auto_rc_source startup
check expect_option tclaude_auto_rc_used ''

printf '%s' '{}' | invoke "$first" prompt || fail 'stale hook'
check expect_option tclaude_auto_rc_used ''
zmodload zsh/system
zsystem flock -t 0 -f held "$lockfile" || fail 'test lock'
printf '%s' 'not JSON' | invoke "$second" prompt || fail 'prompt blocked behind launch lock'
check expect_option tclaude_auto_rc_used 1
zsystem flock -u "$held"
printf '%s' '{}' | invoke "$second" start || fail 'ambiguous start hook'
check expect_option tclaude_auto_rc_used 1

print -r -- "auto-remote-control: $checks checks passed"
