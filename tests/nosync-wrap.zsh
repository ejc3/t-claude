#!/usr/bin/env zsh
# nosync-wrap exits with its child's status, so the launch line can tell a clean /exit from a
# claude that failed to start (the window must stay open to show that error).
emulate -R zsh
wrap="${0:A:h:h}/nosync-wrap"
test_checks=0
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }
check() { (( test_checks++ )); "$@" || fail "$*"; }
rc() { eval "$*" </dev/null >/dev/null 2>&1; print -r -- $?; }
check test "$(rc "$wrap sh -c 'exit 0'")" = 0
check test "$(rc "$wrap sh -c 'exit 3'")" = 3
check test "$(rc "$wrap sh -c 'kill -TERM \$\$'")" = 143
# A missing command reads like the shell's own error, with its status -- not a traceback.
out="$(sleep 1 | "$wrap" no-such-command-tclaude 2>&1)"; rc=$?   # stdin open, as a terminal is
check test $rc = 127
check test "${out//$'\r'/}" = 'nosync-wrap: no-such-command-tclaude: command not found'
out="$(sleep 1 | "$wrap" '' 2>&1)"; rc=$?
check test $rc = 127
check test "${out//$'\r'/}" = 'nosync-wrap: : command not found'
print -r -- "ok: $test_checks checks"
