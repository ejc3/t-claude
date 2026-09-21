#!/usr/bin/env zsh
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-profile-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
mkdir -p "$test_root/project with spaces"
cd "$test_root/project with spaces" || exit 1
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
contains() { [[ "$1" == *"$2"* ]]; }

_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
functions[_tclaude_real_pane_alive]="$functions[_tclaude_pane_alive]"
_tclaude_pane_alive() { (( test_live )); }
nosync-wrap() { "$@"; }
claude-master() { print -rl -- "$@" > "$test_root/argv"; return 1; }
claude() { print -rl -- "$@" > "$test_root/argv"; return 1; }
stty() { print -r -- '-icanon'; }   # the pane's line editor is up
# The pane's shell owns its terminal (at its prompt): its pid is its foreground group.
ps() { [[ "$1 $2 $3" == "-o tpgid= -p" ]] && { print -r -- "  $4"; return; }; command ps "$@"; }

reset_case() {
  test_exists=0 test_reuse=0 test_live=0 test_sent="" test_meta="" test_launch=""
  test_fail_write="" test_fail_read=0
  : > "$test_root/tmux"
  : > "$test_root/stderr"
  : > "$test_root/argv"
}

tmux() {
  print -r -- "${(j: :)${(@q)@}}" >> "$test_root/tmux"
  case "$1" in
    has-session) return 0 ;;
    list-windows)
      if [[ "$argv[-1]" == '#{window_id} #{@tclaude_key}' ]] && (( test_exists )); then
        print -r -- "@1 $key"
      fi
      # An exited window of this folder under ANOTHER key: the reuse-by-folder candidate.
      if [[ "$argv[-1]" == *'#{@tclaude_path}'* ]] && (( test_reuse )); then
        print -r -- "@1"$'\t'"other-key"$'\t'"$PWD"$'\t'"claude"
      fi ;;
    new-window) print -r -- '@1' ;;
    display-message)
      case "$argv[-1]" in
        '#{pane_pid}') print -r -- 12345 ;;
        '#{pane_id}') print -r -- %1 ;;
        '#{pane_id} #{pane_pid}') print -r -- '%1 12345' ;;
        '#{pid}') print -r -- 999 ;;
        '#{pane_tty}') print -r -- /dev/null ;;
        '#{@tclaude_agent}') print -r -- claude ;;
      esac ;;
    show-options)
      case "$argv[-1]" in
        @tclaude_inference) (( test_fail_read )) && return 1; print -r -- "$test_meta" ;;
        @tclaude_launch) print -r -- "$test_launch" ;;
      esac ;;
    set-option)
      [[ "$argv[2]" == -wu && "$argv[-1]" == @tclaude_inference ]] && { test_meta=""; return 0; }
      [[ -n "$test_fail_write" && "$argv[-2]" == "$test_fail_write" ]] && return 1
      case "$argv[-2]" in
        @tclaude_inference) test_meta="$argv[-1]" ;;
        @tclaude_launch) test_launch="$argv[-1]" ;;
      esac ;;
    # The pane is typed ` . <launch file>`; record what that file runs.
    send-keys)
      [[ "$argv[-2]" == -- && "$argv[-3]" == -l ]] && test_sent="$(<"${(Q)${argv[-1]# . }}")"
      [[ "$argv[-1]" == Enter ]] && test_live=1 ;;   # the typed agent runs
    kill-session) fail 'test attempted to kill a tmux session' ;;
  esac
  return 0
}

run_case() { t-claude "$@" </dev/null 2> "$test_root/stderr"; }
reject_case() {
  reset_case
  run_case "$@" && fail "accepted invalid arguments: $*"
  check test -z "$test_sent"
}

reset_case
check run_case --inference-profile first --inference-profile=second --inference-profile third --inference-model claude-sonnet-4-6 --remote-control --resume conversation
check contains "$test_sent" 'nosync-wrap claude-master run first --fallback-profile second --fallback-profile third --model claude-sonnet-4-6 -- --resume conversation'
check contains "$test_sent" '--settings'
check contains "$test_sent" '--remote-control'
check test "$test_meta" = 'profiles-v2 claude-sonnet-4-6 first second third'
check test "${test_sent//--inference-profile/}" = "$test_sent"
(eval "$test_sent")
actual_args=("${(@f)$(<"$test_root/argv")}")
check test "$actual_args[1]" = run
check test "$actual_args[2]" = first
check test "$actual_args[3]" = --fallback-profile
check test "$actual_args[4]" = second
check test "$actual_args[5]" = --fallback-profile
check test "$actual_args[6]" = third
check test "$actual_args[9]" = --
check test "$actual_args[10]" = --resume
check test "$actual_args[11]" = conversation

reset_case
check run_case Work --inference-profile only --inference-model claude-sonnet-4-6 --session-id 11111111-1111-1111-1111-111111111111 --append-system-prompt 'text with spaces; $(not-a-command)'
check contains "$test_sent" '--session-id 11111111-1111-1111-1111-111111111111'
(eval "$test_sent")
actual_args=("${(@f)$(<"$test_root/argv")}")
check test "$actual_args[-1]" = 'text with spaces; $(not-a-command)'

reset_case
check run_case --remote-control
check contains "$test_sent" 'nosync-wrap claude --dangerously-skip-permissions'
check test -z "$test_meta"

reset_case
check run_case -- --inference-profile literal-prompt
check contains "$test_sent" 'nosync-wrap claude '
check contains "$test_sent" '-- --inference-profile literal-prompt'

reject_case --inference-profile
reject_case --inference-profile= --inference-model model
reject_case --inference-profile first
reject_case --inference-model model
reject_case --inference-profile first --inference-model
reject_case --inference-profile first --inference-model=
reject_case --inference-profile first --inference-profile first --inference-model model
reject_case --inference-profile '../escape' --inference-model model
reject_case --inference-profile 'first; echo injected' --inference-model model
reject_case --inference-profile _bad --inference-model model
reject_case --inference-profile first --inference-model model --agent-cmd 'claude'
export TCLAUDE_AGENT_CMD=claude
reject_case --inference-profile first --inference-model model
unset TCLAUDE_AGENT_CMD

reset_case
test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first saved-second'
check run_case --resume conversation
check contains "$test_sent" 'claude-master run saved-first --fallback-profile saved-second --model claude-sonnet-4-6 -- --resume conversation'
# A relaunch from saved profiles keeps the renderer and link settings of every other launch.
check contains "$test_sent" 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=${CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN:-1} TERM_PROGRAM_VERSION=${TERM_PROGRAM_VERSION:+${TERM_PROGRAM_VERSION#next-}} nosync-wrap claude-master run saved-first'
check test "$test_meta" = 'profiles-v2 claude-sonnet-4-6 saved-first saved-second'

reset_case
test_exists=1 test_live=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first saved-second'
check run_case --inference-profile replacement --inference-model claude-opus-4-6
check test -z "$test_sent"
check test "$test_meta" = 'profiles-v2 claude-sonnet-4-6 saved-first saved-second'
check contains "$(<"$test_root/stderr")" 'were not changed'

for broken in missing-mode missing-model empty-profiles invalid-profile duplicate-profile bad-mode legacy-v1 failed-read; do
  reset_case
  test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first saved-second'
  case "$broken" in
    missing-mode) test_meta='claude-sonnet-4-6 saved-first saved-second' ;;
    missing-model) test_meta='profiles-v2 saved-first' ;;
    empty-profiles) test_meta='profiles-v2 claude-sonnet-4-6' ;;
    invalid-profile) test_meta='profiles-v2 claude-sonnet-4-6 saved-first ../escape' ;;
    duplicate-profile) test_meta='profiles-v2 claude-sonnet-4-6 saved-first saved-first' ;;
    bad-mode) test_meta='unknown claude-sonnet-4-6 saved-first' ;;
    # The earlier v1 layout carried a key before the model: never read with shifted fields.
    legacy-v1) test_meta='profiles-v1 1234_5678 claude-sonnet-4-6 saved-first' ;;
    failed-read) test_fail_read=1 ;;
  esac
  run_case && fail "accepted broken saved configuration: $broken"
  check test -z "$test_sent"
done

reset_case
# A failed write stops the launch and leaves the previous value whole (one option, one write).
test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 old' test_fail_write=@tclaude_inference
run_case --inference-profile first --inference-model claude-opus-4-6 && fail 'launched after metadata write failure'
check test -z "$test_sent"
check test "$test_meta" = 'profiles-v2 claude-sonnet-4-6 old'

reset_case
test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 old'
check run_case --inference-profile replacement --inference-model claude-opus-4-6
check contains "$test_sent" 'claude-master run replacement --model claude-opus-4-6'
check test "$test_meta" = 'profiles-v2 claude-opus-4-6 replacement'
# The one write is the whole replacement: no separate option can keep the old model.
check test "$(grep -c 'set-option -w -t @1 @tclaude_inference ' "$test_root/tmux")" = 1

# Another agent taking an exited profile window over clears its saved inference.
reset_case
test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first'
check run_case --agent-cmd 'other-agent --flag'
check contains "$test_sent" 'other-agent --flag'
check test -z "$test_meta"

reject_case --inference-profile first --inference-model 'model with spaces'
reject_case --inference-profile first --inference-model model --agent-label custom
export TCLAUDE_AGENT_LABEL=custom
reject_case --inference-profile first --inference-model model
unset TCLAUDE_AGENT_LABEL

# The saved value names no conversation key: /clear, /branch and /cd re-key the window (the
# same claude-master process carries on) and a relaunch keeps the profiles.
check test "${${(z)test_meta}[2]}" = claude-sonnet-4-6 -o -z "$test_meta"
reset_case
test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first'
check run_case --resume after-clear-id
check contains "$test_sent" 'claude-master run saved-first --model claude-sonnet-4-6 -- --resume after-clear-id'

# Saved profiles do not run under a custom agent label (its liveness check would miss them).
reset_case
test_exists=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first'
TCLAUDE_AGENT_LABEL=custom run_case --resume conversation && fail 'saved profiles launched under a custom label'
check test -z "$test_sent"

# A DIFFERENT launch re-keying an exited window by folder: its saved inference was the old
# agent's, so this one starts native and the value is cleared.
reset_case
test_reuse=1 test_meta='profiles-v2 claude-sonnet-4-6 saved-first'
check run_case --resume conversation
check contains "$test_sent" 'nosync-wrap claude --resume conversation '
check test "${test_sent//claude-master/}" = "$test_sent"
check test -z "$test_meta"

reset_case
# claude-master is looked up in the pane, where it runs: a missing one fails there with
# "command not found" (127, which keeps the window open) and never falls back to native claude.
unfunction claude-master
check run_case --inference-profile first --inference-model model
check contains "$test_sent" 'claude-master run first'
( PATH=/nonexistent; eval "$test_sent"; print -r -- "shell kept" ) > "$test_root/out" 2>&1
check contains "$(<"$test_root/out")" 'not found'
check contains "$(<"$test_root/out")" 'shell kept'
check test ! -s "$test_root/argv"

# A suspended or wrapped claude-master counts as the existing agent; never stack another.
pgrep() { print -r -- 777; }
ps() { print -r -- "$test_process"; }   # (replaces the tpgid stub for these liveness cases)
for test_process in '/opt/bin/claude-master run first --model model' '/usr/bin/python3 /usr/local/bin/nosync-wrap claude-master run first --model model' 'nosync-wrap claude-master run first --model model'; do
  check _tclaude_real_pane_alive 12345 claude
done
test_process='less /tmp/claude-master-notes'
_tclaude_real_pane_alive 12345 claude && fail 'mistook unrelated child for live Claude'

rm -rf "$test_root"
print -r -- "PASS: $test_checks checks"
