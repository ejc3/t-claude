#!/usr/bin/env zsh
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-profile-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude"
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

reset_case() {
  test_exists=0 test_live=0 test_sent="" test_mode="" test_profiles="" test_model=""
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
      fi ;;
    new-window) print -r -- '@1' ;;
    display-message)
      case "$argv[-1]" in
        '#{pane_pid}') print -r -- 12345 ;;
        '#{@tclaude_agent}') print -r -- claude ;;
      esac ;;
    show-options)
      case "$argv[-1]" in
        @tclaude_inference_mode) (( test_fail_read )) && return 1; print -r -- "$test_mode" ;;
        @tclaude_inference_profiles) print -r -- "$test_profiles" ;;
        @tclaude_inference_model) print -r -- "$test_model" ;;
      esac ;;
    set-option)
      [[ -n "$test_fail_write" && "$argv[-2]" == "$test_fail_write" ]] && return 1
      case "$argv[-2]" in
        @tclaude_inference_mode) test_mode="$argv[-1]" ;;
        @tclaude_inference_profiles) test_profiles="$argv[-1]" ;;
        @tclaude_inference_model) test_model="$argv[-1]" ;;
      esac ;;
    send-keys)
      [[ "$argv[-1]" == Enter ]] && test_sent="$argv[-2]" ;;
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
check test "$test_mode" = profiles-v1
check test "$test_profiles" = 'first second third'
check test "$test_model" = claude-sonnet-4-6
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
check test -z "$test_mode"

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
test_exists=1 test_mode=profiles-v1 test_profiles='saved-first saved-second' test_model=claude-sonnet-4-6
check run_case --resume conversation
check contains "$test_sent" 'claude-master run saved-first --fallback-profile saved-second --model claude-sonnet-4-6 -- --resume conversation'
check test "$test_profiles" = 'saved-first saved-second'

reset_case
test_exists=1 test_live=1 test_mode=profiles-v1 test_profiles='saved-first saved-second' test_model=claude-sonnet-4-6
check run_case --inference-profile replacement --inference-model claude-opus-4-6
check test -z "$test_sent"
check test "$test_profiles" = 'saved-first saved-second'
check test "$test_model" = claude-sonnet-4-6
check contains "$(<"$test_root/stderr")" 'were not changed'

for broken in missing-mode missing-model empty-profiles invalid-profile duplicate-profile bad-mode failed-read; do
  reset_case
  test_exists=1 test_mode=profiles-v1 test_profiles='saved-first saved-second' test_model=claude-sonnet-4-6
  case "$broken" in
    missing-mode) test_mode="" ;;
    missing-model) test_model="" ;;
    empty-profiles) test_profiles="" ;;
    invalid-profile) test_profiles='saved-first ../escape' ;;
    duplicate-profile) test_profiles='saved-first saved-first' ;;
    bad-mode) test_mode=unknown ;;
    failed-read) test_fail_read=1 ;;
  esac
  run_case && fail "accepted broken saved configuration: $broken"
  check test -z "$test_sent"
done

reset_case
test_fail_write=@tclaude_inference_model
run_case --inference-profile first --inference-model claude-sonnet-4-6 && fail 'launched after metadata write failure'
check test -z "$test_sent"
check test "$test_mode" = profiles-v1

reset_case
test_exists=1 test_mode=profiles-v1 test_profiles='old' test_model=claude-sonnet-4-6
check run_case --inference-profile replacement --inference-model claude-opus-4-6
check contains "$test_sent" 'claude-master run replacement --model claude-opus-4-6'
check test "$test_profiles" = replacement

reset_case
unfunction claude-master
# `command` is a zsh builtin: this stub deliberately hides any real installed launcher.
command() { [[ "$*" == '-v claude-master' ]] && return 1; builtin command "$@"; }
run_case --inference-profile first --inference-model model && fail 'launched without claude-master'
check test -z "$test_sent"
unfunction command

# A suspended or wrapped claude-master counts as the existing agent; never stack another.
pgrep() { print -r -- 777; }
ps() { print -r -- "$test_process"; }
for test_process in '/opt/bin/claude-master run first --model model' '/usr/bin/python3 /usr/local/bin/nosync-wrap claude-master run first --model model' 'nosync-wrap claude-master run first --model model'; do
  check _tclaude_real_pane_alive 12345 claude
done
test_process='less /tmp/claude-master-notes'
_tclaude_real_pane_alive 12345 claude && fail 'mistook unrelated child for live Claude'

print -r -- "PASS: $test_checks checks; isolated fixtures: $test_root"
