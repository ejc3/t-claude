#!/usr/bin/env zsh
# A terminal's grouped view gets the options the real session has, because a view has its own
# session options: status off, and mouse off (tmux next-3.8+ defaults mouse on, which takes a
# phone's swipes away from its own scrollback). Runs against a private tmux server.
emulate -R zsh
setopt pipefail
local_repo="${0:A:h:h}"
source "$local_repo/t-claude.zsh" || exit 1
test_root="$(mktemp -d "${TMPDIR:-/tmp}/tclaude-view-tests.XXXXXXXX")" || exit 1
unset TMUX TMUX_PANE
real_tmux="${TCLAUDE_TMUX:-$(command -v tmux-scroll || command -v tmux)}"
tmux() { command "$real_tmux" -S "$test_root/sock" -f /dev/null "$@"; }
trap 'tmux kill-server 2>/dev/null; rm -rf "$test_root"' EXIT
test_checks=0
fail() { print -u2 -r -- "FAIL: $* (fixtures: $test_root)"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }

tmux new-session -d -s main -x 80 -y 24 'exec sleep 100000' || fail "new-session"
tmux set-option -g mouse on          # what a next-3.8+ server starts with
win="$(tmux display-message -p -t main '#{window_id}')"
view="$(_tclaude_mint_view main "$win")"
check [ -n "$view" ]
check [ "$(tmux show-options -t "$view" -v mouse)" = off ]
check [ "$(tmux show-options -t "$view" -v status)" = off ]
print -r -- "ok: $test_checks checks"
