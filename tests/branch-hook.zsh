#!/usr/bin/env zsh
# /branch turns a pane into the new conversation. The session hook re-stamps the window with the
# new id and then calls the optional branch-hook extension, which has to be told the id that
# was replaced: after the re-stamp nothing else records which conversation the pane left.
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-branch-tests.XXXXXXXX")" || exit 1
export HOME="$test_root/home" XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp"
unset TMUX TMUX_PANE TCLAUDE_ARGS TCLAUDE_AGENT_CMD TCLAUDE_AGENT_LABEL
mkdir -p "$HOME" "$test_root/project" "$test_root/bin"
cd "$test_root/project" || exit 1
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }

# A launch writes the session hook. Nothing here needs the window it would create.
_tclaude_use_patched_tmux() { :; }
_tclaude_relabel() { :; }
_tclaude_native_screen() { :; }
_tclaude_pane_alive() { return 1; }
nosync-wrap() { "$@"; }
claude() { return 1; }
stty() { print -r -- '-icanon'; }
tmux() {
  case "$1" in
    new-window) print -r -- '@1' ;;
    display-message)
      case "$argv[-1]" in
        '#{pane_pid}') print -r -- 12345 ;;
        '#{pane_id}') print -r -- %1 ;;
        '#{pane_id} #{pane_pid}') print -r -- '%1 12345' ;;
        '#{pane_tty}') print -r -- /dev/null ;;
      esac ;;
  esac
  return 0
}
t-claude </dev/null >/dev/null 2>&1
unfunction tmux
ssync="$XDG_CACHE_HOME/t-claude/session-sync.sh"
check test -x "$ssync"

# The window as the hook finds it: managed, showing the conversation $before.
before="11111111-1111-4111-8111-111111111111"
after="22222222-2222-4222-8222-222222222222"
cat > "$test_root/bin/tmux" <<TMUX
#!/bin/sh
case "\$*" in
  *'@tclaude_key}'*)     echo key ;;
  *'@tclaude_resume}'*)  echo $before ;;
  *'@tclaude_path}'*)    echo "$test_root/project" ;;
  *'@tclaude_managed}'*) echo 1 ;;
esac
exit 0
TMUX
cat > "$XDG_CACHE_HOME/t-claude/branch-hook" <<'HOOK'
#!/bin/sh
printf 'pane=%s sid=%s cwd=%s prev=%s\n' "$TC_PANE" "$TC_SID" "$TC_CWD" "$TC_PREV_SID" >> "$TEST_HOOK_LOG"
HOOK
chmod +x "$test_root/bin/tmux" "$XDG_CACHE_HOME/t-claude/branch-hook"
export TEST_HOOK_LOG="$test_root/hook.log"

run_hook() {  # run_hook SOURCE: feed the session hook what claude sends at session start
  : > "$TEST_HOOK_LOG"
  print -r -- "{\"session_id\":\"$after\",\"source\":\"$1\",\"cwd\":\"$test_root/project\"}" \
    | PATH="$test_root/bin:$PATH" TMUX="$test_root/sock,1,0" TMUX_PANE=%1 sh "$ssync"
}

run_hook fork
check test "$(<"$TEST_HOOK_LOG")" = "pane=%1 sid=$after cwd=$test_root/project prev=$before"

# /clear and a plain resume also start a session, and neither is a branch.
run_hook clear
check test ! -s "$TEST_HOOK_LOG"
run_hook resume
check test ! -s "$TEST_HOOK_LOG"

rm -rf "$test_root"
print -r -- "ok: $test_checks checks"
