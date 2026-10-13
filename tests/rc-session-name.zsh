#!/usr/bin/env zsh
# A bare --remote-control gets a session name: the box (TCLAUDE_BOX, else the short hostname) and the
# folder, so sessions are not told apart by a random word. A name the caller gave is kept. No real
# tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-rcname-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
# The variables carried (the test's own list: the contract, not the implementation's).
model_vars=(ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL)
unset "${model_vars[@]}"
mkdir -p "$test_root/my game"
cd "$test_root/my game" || exit 1
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

unset TCLAUDE_BOX
# A bare flag, the box named: the name follows the flag as one argument.
reset_case
TCLAUDE_BOX=fcvm check run_case --remote-control
check contains "$test_sent" "--remote-control fcvm\\ my\\ game"

# Not named: the short hostname.
reset_case
HOST=ip-10-0-0-1.us-west-1.compute.internal check run_case --remote-control
check contains "$test_sent" "--remote-control ip-10-0-0-1\\ my\\ game"

# The alias, followed by another flag.
reset_case
TCLAUDE_BOX=nextjs check run_case --rc --effort high
check contains "$test_sent" "--rc nextjs\\ my\\ game --effort high"

# From TCLAUDE_ARGS, as agents-start sets it.
reset_case
TCLAUDE_BOX=fcvm TCLAUDE_ARGS=--remote-control check run_case
check contains "$test_sent" "--remote-control fcvm\\ my\\ game"

# A name the caller gave is kept, and so is a prefix.
reset_case
TCLAUDE_BOX=fcvm check run_case --remote-control mine
check contains "$test_sent" "--remote-control mine"
check test "${test_sent//fcvm\\ my\\ game/}" = "$test_sent"
reset_case
TCLAUDE_BOX=fcvm check run_case --remote-control --remote-control-session-name-prefix pre
check test "${test_sent//fcvm\\ my\\ game/}" = "$test_sent"

# No remote control: nothing added.
reset_case
TCLAUDE_BOX=fcvm check run_case
check test "${test_sent//--remote-control/}" = "$test_sent"

print -r -- "rc-session-name: $test_checks checks passed"
rm -rf "$test_root"
