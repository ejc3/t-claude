#!/usr/bin/env zsh
# t-claude works whatever options the user's shell sets before sourcing it: the file is parsed
# and its functions run under zsh's own options (see SHELL OPTIONS in t-claude.zsh).
# No real tmux server, Claude executable, credentials or home configuration is touched.
emulate -R zsh
here="${0:A:h}"
if [[ "${1-}" == --case ]]; then
  # The option is on while the file is sourced, as a ~/.zshrc setting would be.
  case "$TEST_OPT" in
    IFS_NEWLINE) IFS=$'\n'; source "$here/../t-claude.zsh" || exit 1 ;;
    PIPE) source <(cat "$here/../t-claude.zsh") || exit 1 ;;
    STALE_GUARD_VAR) _TCLAUDE_EMULATED=x; setopt SH_GLOB; source "$here/../t-claude.zsh" || exit 1 ;;
    # A function snapshot: t-claude copied without its sticky options, run under KSH_ARRAYS.
    SNAPSHOT) source "$here/../t-claude.zsh" || exit 1
              functions[t-claude]="$functions[t-claude]"; setopt KSH_ARRAYS NO_CLOBBER ;;
    *) setopt "$TEST_OPT"; source "$here/../t-claude.zsh" || exit 1 ;;
  esac
  (( ${+functions[t-claude]} )) || { print -r -- 'not defined'; exit 1; }
  _tclaude_use_patched_tmux() { :; }
  _tclaude_relabel() { :; }
  _tclaude_native_screen() { :; }
  _tclaude_pane_alive() { [[ -e "$TEST_ROOT/typed" ]]; }   # the agent runs once it is typed
  stty() { print -r -- '-icanon'; }
  tmux() {
    print -r -- "$*" >> "$TEST_ROOT/tmux"
    [[ "$1 ${@[-1]}" == 'send-keys Enter' ]] && : >| "$TEST_ROOT/typed"
    case "$*" in
      new-window*) print -r -- '@1' ;;
      *'#{pane_id}') print -r -- %1 ;;
      *'#{pane_pid}') print -r -- 12345 ;;
      *'#{pane_tty}') print -r -- /dev/null ;;
    esac
    return 0
  }
  cd "$TEST_ROOT/project" || exit 1
  t-claude --resume some-id </dev/null 2>> "$TEST_ROOT/stderr"
  exit $?
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-options-tests.XXXXXXXX")" || exit 1
mkdir -p "$test_root/project"
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
for opt in SH_GLOB KSH_ARRAYS NOUNSET NO_CLOBBER GLOB_SUBST NO_MULTIOS IFS_NEWLINE PIPE STALE_GUARD_VAR SNAPSHOT; do
  : > "$test_root/tmux"; : > "$test_root/stderr"; rm -f "$test_root/typed"
  HOME="$test_root/home" XDG_CACHE_HOME="$test_root/cache" CLAUDE_CONFIG_DIR="$test_root/claude" TMUX_TMPDIR="$test_root/tmux-tmp" \
    TEST_ROOT="$test_root" TEST_OPT="$opt" TMUX= TMUX_PANE= TCLAUDE_ARGS= \
    zsh -f "$0" --case > "$test_root/out" 2>&1 || fail "$opt: $(<"$test_root/out") $(<"$test_root/stderr")"
  # The launch reached the pane: whole line, or the launch file that holds it.
  launched="$(<"$test_root/tmux")"
  for f in "$test_root"/cache/t-claude/launch/*(N); do launched+="$(<"$f")"; done
  check test -n "${(M)launched:#*nosync-wrap claude --resume some-id*}"
  check test -z "$(grep -v "ready in session" "$test_root/stderr")"
done
rm -rf "$test_root"
print -r -- "ok: $test_checks checks"
