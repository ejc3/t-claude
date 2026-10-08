#!/usr/bin/env zsh
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-server-tests.XXXXXXXX")" || exit 1
export XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL TCLAUDE_INFERENCE_SERVER TCLAUDE_INFERENCE_DIR
# The caller's model settings would be carried into every launch here (tests/model-env.zsh
# is where they are tested).
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
  ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
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


# ---- an explicit server: claude-master connect replaces claude, every other flag survives
reset_case
check run_case --inference-server 203.0.113.5:8443 --remote-control --resume conversation
check contains "$test_sent" 'nosync-wrap claude-master connect --server 203.0.113.5:8443 --dir "$HOME/.config/claude-master" -- --resume conversation'
check contains "$test_sent" '--settings'
check contains "$test_sent" '--remote-control'
check test "$test_meta" = 'server-v1 203.0.113.5:8443 -'
check test "${test_sent//--inference-server/}" = "$test_sent"
(eval "$test_sent")
actual_args=("${(@f)$(<"$test_root/argv")}")
check test "$actual_args[1]" = connect
check test "$actual_args[2]" = --server
check test "$actual_args[3]" = 203.0.113.5:8443
check test "$actual_args[4]" = --dir
check test "$actual_args[5]" = "$HOME/.config/claude-master"
check test "$actual_args[6]" = --
check test "$actual_args[7]" = --resume
check test "$actual_args[8]" = conversation

# ---- the default client directory is the HOME of the shell that RUNS the line, not of the one that built it
reset_case
check run_case --inference-server 203.0.113.5:8443 --remote-control
check contains "$test_sent" '"$HOME/.config/claude-master"'
check test "${test_sent//$HOME\/.config/}" = "$test_sent"      # the caller's HOME is not baked into the line
(HOME=/home/pane-user; eval "$test_sent")
actual_args=("${(@f)$(<"$test_root/argv")}")
check test "$actual_args[5]" = /home/pane-user/.config/claude-master

# ---- a client directory, an auto launch (what an unattended launcher runs), and a name with a space
reset_case
check run_case --auto --remote-control --inference-server=pool.internal:8443 --inference-dir /home/example/.config/claude-master
check contains "$test_sent" 'claude-master connect --server pool.internal:8443 --dir /home/example/.config/claude-master -- '
check contains "$test_sent" '--remote-control'
check test "$test_meta" = 'server-v1 pool.internal:8443 /home/example/.config/claude-master'

# ---- the environment is the default for a launch that asked for nothing else
reset_case
export TCLAUDE_INFERENCE_SERVER=203.0.113.5:8443
check run_case --remote-control
check contains "$test_sent" 'nosync-wrap claude-master connect --server 203.0.113.5:8443 --dir "$HOME/.config/claude-master" -- '
check test "$test_meta" = 'server-v1 203.0.113.5:8443 -'
export TCLAUDE_INFERENCE_DIR=/home/example/.cfg
reset_case
check run_case --remote-control
check contains "$test_sent" '--server 203.0.113.5:8443 --dir /home/example/.cfg --'
unset TCLAUDE_INFERENCE_DIR

# ---- ...and anything explicit wins over it, so no other launch is ever changed by it
reset_case
check run_case --inference-profile first --inference-model claude-sonnet-4-6 --remote-control
check contains "$test_sent" 'claude-master run first --model claude-sonnet-4-6 -- '
check test "${test_sent//connect/}" = "$test_sent"
check test "$test_meta" = 'profiles-v2 claude-sonnet-4-6 first'
reset_case
check run_case --agent-cmd 'echo custom'
check test "${test_sent//connect/}" = "$test_sent"
check test -z "$test_meta"
reset_case
check run_case --inference-server other.internal:9000 --remote-control
check contains "$test_sent" '--server other.internal:9000 --dir'
check test "${test_sent//203.0.113.5/}" = "$test_sent"
unset TCLAUDE_INFERENCE_SERVER

# ---- a relaunch of the window uses the saved server (across /clear, /branch and /cd), not a plain claude
reset_case
test_exists=1 test_meta='server-v1 saved.internal:8443 /home/example/.cfg'
check run_case --resume conversation
check contains "$test_sent" 'claude-master connect --server saved.internal:8443 --dir /home/example/.cfg -- --resume conversation'
check test "$test_meta" = 'server-v1 saved.internal:8443 /home/example/.cfg'
# ...even with a different server in the environment
reset_case
export TCLAUDE_INFERENCE_SERVER=env.internal:8443
test_exists=1 test_meta='server-v1 saved.internal:8443 -'
check run_case --resume conversation
check contains "$test_sent" '--server saved.internal:8443 --dir "$HOME/.config/claude-master" -- --resume conversation'
unset TCLAUDE_INFERENCE_SERVER

# ---- fail closed: a saved value that cannot be read never starts a plain claude
for bad in 'server-v1 onlyone' 'server-v1 a:1 - extra' 'server-v1 bad;x:1 -' 'server-v1 host:99999 -' 'server-v1 h:1 ../escape'; do
  reset_case
  test_exists=1 test_meta="$bad"
  run_case --resume conversation && fail "relaunched from an unreadable saved value: $bad"
  check test -z "$test_sent"
done
reset_case
test_exists=1 test_meta='server-v1 saved.internal:8443 -' test_fail_read=1
run_case --resume conversation && fail "launched when the saved option could not be read"
check test -z "$test_sent"
# a failed write stops the launch, like the profile form
reset_case
test_fail_write=@tclaude_inference
run_case --inference-server h.internal:8443 --remote-control && fail "launched after a failed write of the saved server"
check test -z "$test_sent"

# ---- rejected arguments: nothing is sent to the pane
reject_case --inference-server
reject_case --inference-server=
reject_case --inference-server host
reject_case --inference-server host:0
reject_case --inference-server host:99999
reject_case --inference-server 'ho st:1'
reject_case --inference-server 'h;echo x:1'
reject_case --inference-server '$(id):1'
reject_case --inference-server a:b:1
reject_case --inference-server ':1'
reject_case --inference-server h:1 --inference-dir relative/dir
reject_case --inference-server h:1 --inference-dir '/with space'
reject_case --inference-server h:1 --inference-dir '/a/../b'
reject_case --inference-server h:1 --inference-dir '/a;b'
reject_case --inference-dir /home/example/.cfg
reject_case --inference-server h:1 --inference-profile first --inference-model m
reject_case --inference-server h:1 --inference-model m
reject_case --inference-server h:1 --agent-cmd 'claude'
reject_case --inference-server h:1 --agent-label other
export TCLAUDE_AGENT_CMD=claude
reject_case --inference-server h:1
unset TCLAUDE_AGENT_CMD
# a bad value in the environment is an error too, not a silent plain claude
export TCLAUDE_INFERENCE_SERVER='bad;value:1'
reject_case --remote-control
unset TCLAUDE_INFERENCE_SERVER

# ---- after "--" everything is the prompt, even our own flag names
reset_case
check run_case -- --inference-server literal-prompt
check contains "$test_sent" 'nosync-wrap claude '
check contains "$test_sent" '-- --inference-server literal-prompt'
check test -z "$test_meta"

print -r -- "PASS: $test_checks checks"
rm -rf "$test_root"
