#!/usr/bin/env zsh
# Claude's model variables (ANTHROPIC_MODEL and the rest) reach the claude t-claude launches:
# it runs in a tmux pane whose shell has the tmux server's environment, not the caller's, so
# `ANTHROPIC_MODEL=x t-claude` used to start claude without it. No real tmux server, Claude
# executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-model-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
# The variables carried (the test's own list: the contract, not the implementation's).
model_vars=(ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL)
unset "${model_vars[@]}"
mkdir -p "$test_root/project"
cd "$test_root/project" || exit 1
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
contains() { [[ "$1" == *"$2"* ]]; }

_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
_tclaude_pane_alive() { (( test_live )); }
nosync-wrap() { "$@"; }
# What the launched claude sees: each model variable, or "-" when it is not set.
record_env() {
  local v
  for v in "${model_vars[@]}"; do
    if [[ -v $v ]]; then print -r -- "$v=${(P)v}"; else print -r -- "$v -"; fi
  done > "$test_root/env"
}
claude() { record_env; return 1; }
claude-master() { record_env; return 1; }
stty() { print -r -- '-icanon'; }
ps() { [[ "$1 $2 $3" == "-o tpgid= -p" ]] && { print -r -- "  $4"; return; }; command ps "$@"; }

reset_case() {
  test_exists=0 test_reuse=0 test_live=0 test_sent="" test_env_opt="" test_inference=""
  test_fail_write=""
  : > "$test_root/tmux"
  : > "$test_root/stderr"
  : > "$test_root/env"
}

tmux() {
  print -r -- "${(j: :)${(@q)@}}" >> "$test_root/tmux"
  case "$1" in
    has-session) return 0 ;;
    list-windows)
      if [[ "$argv[-1]" == '#{window_id} #{@tclaude_key}' ]] && (( test_exists )); then
        print -r -- "@1 $key"
      fi
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
        @tclaude_model_env) print -r -- "$test_env_opt" ;;
        @tclaude_inference) print -r -- "$test_inference" ;;
      esac ;;
    set-option)
      if [[ "$argv[2]" == -wu ]]; then
        case "$argv[-1]" in
          @tclaude_model_env) test_env_opt="" ;;
          @tclaude_inference) test_inference="" ;;
        esac
        return 0
      fi
      [[ -n "$test_fail_write" && "$argv[-2]" == "$test_fail_write" ]] && return 1
      case "$argv[-2]" in
        @tclaude_model_env) test_env_opt="$argv[-1]" ;;
        @tclaude_inference) test_inference="$argv[-1]" ;;
      esac ;;
    send-keys)
      [[ "$argv[-2]" == -- && "$argv[-3]" == -l ]] && test_sent="$(<"${(Q)${argv[-1]# . }}")"
      [[ "$argv[-1]" == Enter ]] && test_live=1 ;;
    kill-session) fail 'test attempted to kill a tmux session' ;;
  esac
  return 0
}

run_case() { t-claude "$@" </dev/null 2> "$test_root/stderr"; }
# Run what was typed into the pane, in a shell without the caller's model variables (as the
# pane's is), and report whether the variable outlived the claude command in that shell.
run_sent() {
  ( unset "${model_vars[@]}"; eval "$test_sent"
    [[ -v ANTHROPIC_MODEL ]] && print -r -- leaked > "$test_root/leak" ) >/dev/null 2>&1
}
seen() { grep -qxF -- "$1" "$test_root/env"; }

# The case that failed: the model set for t-claude reaches claude, and only claude.
reset_case
rm -f "$test_root/leak"
ANTHROPIC_MODEL='claude-test-model[1m]' check run_case --resume conversation
check contains "$test_sent" 'ANTHROPIC_MODEL=claude-test-model\[1m\] nosync-wrap claude '
check test "$test_env_opt" = 'env-v1 ANTHROPIC_MODEL=claude-test-model[1m]'
run_sent
check seen 'ANTHROPIC_MODEL=claude-test-model[1m]'
check seen 'CLAUDE_CODE_SUBAGENT_MODEL -'
check test ! -e "$test_root/leak"

# Several at once, each passed as given.
reset_case
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6 CLAUDE_CODE_SUBAGENT_MODEL=us.anthropic.claude-haiku-4-5:0 \
  check run_case
run_sent
check seen 'ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6'
check seen 'CLAUDE_CODE_SUBAGENT_MODEL=us.anthropic.claude-haiku-4-5:0'
check seen 'ANTHROPIC_MODEL -'

# None set: nothing added, nothing saved.
reset_case
check run_case
check test "${test_sent//ANTHROPIC_MODEL/}" = "$test_sent"
check test -z "$test_env_opt"

# An exited window relaunched with no variables set keeps its saved model.
reset_case
test_exists=1 test_env_opt='env-v1 ANTHROPIC_MODEL=claude-test-model[1m]'
check run_case --resume conversation
run_sent
check seen 'ANTHROPIC_MODEL=claude-test-model[1m]'
check test "$test_env_opt" = 'env-v1 ANTHROPIC_MODEL=claude-test-model[1m]'

# One set replaces the saved set whole; set empty, it clears it.
reset_case
test_exists=1 test_env_opt='env-v1 ANTHROPIC_MODEL=old CLAUDE_CODE_SUBAGENT_MODEL=old-sub'
ANTHROPIC_MODEL=new check run_case
run_sent
check seen 'ANTHROPIC_MODEL=new'
check seen 'CLAUDE_CODE_SUBAGENT_MODEL -'
check test "$test_env_opt" = 'env-v1 ANTHROPIC_MODEL=new'
reset_case
test_exists=1 test_env_opt='env-v1 ANTHROPIC_MODEL=old'
ANTHROPIC_MODEL= check run_case
run_sent
check seen 'ANTHROPIC_MODEL -'
check test -z "$test_env_opt"

# Saved together with inference profiles: both reach the relaunch.
reset_case
test_exists=1 test_env_opt='env-v1 ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5'
test_inference='profiles-v2 claude-sonnet-4-6 first'
check run_case --resume conversation
check contains "$test_sent" 'ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5 nosync-wrap claude-master run first'
run_sent
check seen 'ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5'

# Values that are not model names never reach the pane.
for bad in 'model with spaces' 'x;touch pwned' '$(touch pwned)' "quote'd" "${(l:201::m:)}"; do
  reset_case
  ANTHROPIC_MODEL="$bad" run_case && fail "accepted ANTHROPIC_MODEL=$bad"
  check test -z "$test_sent"
  check contains "$(<"$test_root/stderr")" 'invalid ANTHROPIC_MODEL'
done
check test ! -e "$test_root/project/pwned"

# A saved value that cannot be read stops the relaunch (it is not dropped silently).
for broken in 'env-v2 ANTHROPIC_MODEL=x' 'env-v1' 'env-v1 PATH=/tmp' 'env-v1 ANTHROPIC_MODEL=a;b' 'ANTHROPIC_MODEL=x'; do
  reset_case
  test_exists=1 test_env_opt="$broken"
  run_case && fail "accepted broken saved model settings: $broken"
  check test -z "$test_sent"
done
# Setting the variable (even empty) replaces a broken saved value.
reset_case
test_exists=1 test_env_opt='env-v2 junk'
ANTHROPIC_MODEL= check run_case
check test -z "$test_env_opt"

# A failed write stops the launch and leaves the previous value.
reset_case
test_exists=1 test_env_opt='env-v1 ANTHROPIC_MODEL=old' test_fail_write=@tclaude_model_env
ANTHROPIC_MODEL=new run_case && fail 'launched after a failed write of the model settings'
check test -z "$test_sent"
check test "$test_env_opt" = 'env-v1 ANTHROPIC_MODEL=old'

# A running claude is attached, not restarted: told so when its model differs, quiet when not.
reset_case
test_exists=1 test_live=1 test_env_opt='env-v1 ANTHROPIC_MODEL=old'
ANTHROPIC_MODEL=new check run_case
check test -z "$test_sent"
check contains "$(<"$test_root/stderr")" 'its model was not changed'
check test "$test_env_opt" = 'env-v1 ANTHROPIC_MODEL=old'
reset_case
test_exists=1 test_live=1 test_env_opt='env-v1 ANTHROPIC_MODEL=same'
ANTHROPIC_MODEL=same check run_case
check test "${$(<"$test_root/stderr")//not changed/}" = "$(<"$test_root/stderr")"

# A different launch re-keying an exited window by folder: the old agent's model is cleared.
reset_case
test_reuse=1 test_env_opt='env-v1 ANTHROPIC_MODEL=old'
check run_case --resume conversation
check test -z "$test_env_opt"
check test "${test_sent//ANTHROPIC_MODEL/}" = "$test_sent"

# --agent-cmd is a whole command: the variables are not added to it, and it clears the saved ones.
reset_case
test_exists=1 test_env_opt='env-v1 ANTHROPIC_MODEL=old'
ANTHROPIC_MODEL=new check run_case --agent-cmd 'other-agent --flag'
check contains "$test_sent" 'other-agent --flag'
check test "${test_sent//ANTHROPIC_MODEL/}" = "$test_sent"
check test -z "$test_env_opt"

rm -rf "$test_root"
print -r -- "PASS: $test_checks checks"
