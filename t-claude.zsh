# t-claude [SESSION] [--resume <id>]
#
# PREREQUISITES (all provided by the dev-box setup in ejc3/aws dev-user-data.tf; listed
# here so this script is self-documenting if copied elsewhere):
#   - zsh                  this is a zsh function, sourced from ~/.zshrc.
#   - tmux                 3.4+ works; the dev boxes run 3.7b. tmux is attached in NORMAL
#                          client/server mode (NOT `tmux -CC` control mode -- no iOS
#                          client speaks it). Sessions/windows are managed here.
#   - claude               Claude Code on PATH.
#   - nosync-wrap          /usr/local/bin/nosync-wrap -- a pty shim that strips Claude's
#                          synchronized-output sequences (CSI ?2026h/l) so tmux does not
#                          swallow scrollback. OPTIONAL: if absent, launches bare claude
#                          (scrollback breaks, everything else works).
#   - HIST_IGNORE_SPACE    set in ~/.zshrc -- lets the space-prefixed launch command stay
#                          out of shell history (see the `cmd=" $inner"` note below).
#
# NOT required: a pre-configured ~/.tmux.conf. Earlier versions depended on the host having
# deployed the native-scrollback settings (smcup@/rmcup@, status off, indn@, mouse off) into
# a static config file -- correct on the boxes that had it, silently broken (no scrollback,
# no error) on any host where that file was missing, stale, or reverted. t-claude now sets
# those options itself, at runtime, on every invocation -- see APPLY_SCROLLBACK_SETTINGS
# below. This makes the script self-contained: copy it to a fresh host with nothing but zsh
# and tmux installed and scrollback works on the first run, no separate provisioning step.
#
# These are GLOBAL session options, so they apply to the whole tmux SERVER, not just the
# window t-claude creates -- a plain `tmux` invoked later on the same server (no t-claude)
# inherits them too, as long as t-claude has run at least once since that server started.
# A hand-written ~/.tmux.conf can still coexist: it loads once at server start, t-claude's
# settings are asserted after and win regardless of invocation order, so a stray or outdated
# config file can no longer silently break scrollback.
#
#   SESSION : tmux session = a named group of related projects ("Apps","Backend",
#             "AWS"). Omit it and the session defaults to "<folder>-<hash>" (unique
#             per directory).
#   WINDOW  : one per project folder, keyed by folder path (hidden @tclaude_key), so
#             two same-named folders never collide.
#   --resume <id> : a NEW window "<folder>-<id>" (claude session id as discriminator).
#   PANES   : never touched — split your own terminal in with Ctrl-b % / ".
# If you pass a SESSION but this folder's claude is already open in a DIFFERENT
# session, t-claude MOVES it here live (move-window keeps claude running) — no prompt,
# since the move is non-destructive.
# Safety: only windows WE create carry @tclaude_key, so manual windows are never
# found, reused, renamed, moved, or closed.
t-claude() {
  local session="" resume="" folder base cmd key winname win hash explicit=0
  folder="$PWD"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --resume=*) resume="${1#--resume=}"; shift ;;
      --resume)
        if [ -n "${2-}" ] && [ "${2#-}" = "${2-}" ]; then resume="$2"; shift 2; else shift; fi ;;
      -*) shift ;;
      *) [ -z "$session" ] && session="$1"; shift ;;
    esac
  done

  base="${folder##*/}"; [ -z "$base" ] && base="root"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9_-' '_')"

  if [ -n "$session" ]; then
    explicit=1
    session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9_-' '_')"
  else
    hash="$(printf '%s' "$folder" | cksum | awk '{printf "%x", $1}')"
    session="${base}-${hash}"
  fi

  key="$(printf '%s' "$folder" | cksum | awk '{print $1}')_$(printf '%s' "$resume" | cksum | awk '{print $1}')"
  winname="$base"; [ -n "$resume" ] && winname="${base}-$(printf '%s' "$resume" | tr -c 'A-Za-z0-9_-' '_')"
  # nosync-wrap strips Claude's synchronized-output-mode sequences (CSI ?2026h/l)
  # before tmux sees them. tmux buffers all grid updates while sync mode is active and
  # emits only a viewport redraw, so scrolled-off lines never reach the host terminal's
  # native scrollback -- verified by strace on the live process (2026h emitted) and by
  # a 40/40-vs-23/40 scrollback measurement with and without the wrapper. Falls back to
  # bare claude if the wrapper is missing, so t-claude never breaks.
  # Pass --effort here rather than relying on a claude() wrapper in ~/.zshrc: the command
  # runs as `nosync-wrap claude ...`, so the shell runs nosync-wrap and any such function is
  # skipped, leaving the window on the default effort. Exported variables still arrive on
  # their own; a flag cannot, so it belongs in this command.
  local wrap=""; command -v nosync-wrap >/dev/null 2>&1 && wrap="nosync-wrap "
  local flags="--dangerously-skip-permissions --effort ultracode"
  local inner
  if [ -n "$resume" ]; then inner="${wrap}claude --resume $resume $flags"
  else inner="${wrap}claude --resume $flags"; fi

  # Ctrl-Z NOTE: the window is created running your normal interactive shell, and
  # claude is then sent to it as a JOB. Running claude as the pane command directly
  # cannot support Ctrl-Z at all: a pane command is a session leader, so its process
  # group is ORPHANED and POSIX silently discards stop signals. As a shell job it lives
  # in the shell's session, so Ctrl-Z suspends it and `fg` resumes it -- verified.
  # Leading space keeps this out of shell history: ~/.zshrc sets HIST_IGNORE_SPACE, so
  # zsh skips space-prefixed commands. Without it every launch types the full
  # "nosync-wrap claude --resume ..." line into the window's shell and it lands in
  # history, cluttering it and polluting up-arrow / Ctrl-R for the folder you work in.
  cmd=" $inner"

  # already the requested session's window?
  win=""
  if tmux has-session -t "=$session" 2>/dev/null; then
    win="$(tmux list-windows -t "=$session" -F '#{window_id} #{@tclaude_key}' 2>/dev/null | awk -v k="$key" '$2==k {print $1; exit}')"
  fi

  # explicit session, not here yet: if this folder's claude is open in another
  # session, move it here live (non-destructive — claude keeps running).
  if [ -z "$win" ] && [ "$explicit" = 1 ]; then
    local hit osess owin ph
    hit="$(tmux list-windows -a -F '#{session_name} #{window_id} #{@tclaude_key}' 2>/dev/null | awk -v k="$key" '$3==k {print $1" "$2; exit}')"
    if [ -n "$hit" ]; then
      osess="${hit% *}"; owin="${hit#* }"; ph=""
      if ! tmux has-session -t "=$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -c "$folder"
        ph="$(tmux list-windows -t "=$session" -F '#{window_id}' | head -1)"
      fi
      tmux move-window -s "$owin" -t "=$session:"
      [ -n "$ph" ] && tmux kill-window -t "$ph" 2>/dev/null
      win="$owin"
      printf "moved this folder's claude from session '%s' to '%s'\n" "$osess" "$session" >&2
    fi
  fi

  # nothing to reuse/move: add a new window (creating the session if needed)
  local created=0
  if [ -z "$win" ]; then
    # Create the window running the plain interactive shell (no command), then send
    # claude to it as a job -- see the Ctrl-Z note above.
    if tmux has-session -t "=$session" 2>/dev/null; then
      win="$(tmux new-window -d -P -F '#{window_id}' -t "=$session" -n "$winname" -c "$folder")"
    else
      tmux new-session -d -s "$session" -n "$winname" -c "$folder"
      win="$(tmux list-windows -t "=$session" -F '#{window_id}' | head -1)"
    fi
    tmux set-option -w -t "$win" @tclaude_key "$key"
    tmux send-keys -t "$win" "$cmd" Enter
    created=1
  fi

  # Reusing a window whose claude has exited: since the window now runs the shell rather
  # than claude itself, it survives that exit still carrying @tclaude_key, so t-claude
  # would hand you an empty prompt and never start claude again.
  #
  # Look for claude among the window shell's children, not merely for "any child". Running
  # t-claude from inside the very window it is about to reuse -- which is exactly what you
  # do after claude prints "Resume this session with" -- means our own command
  # substitutions are children of that shell, so an any-child test always says claude is
  # alive and silently does nothing. A claude suspended with Ctrl-Z still matches here, so
  # a stopped session never gets a second claude stacked on it.
  if [ "$created" = 0 ]; then
    local pane_pid kid alive=0
    pane_pid="$(tmux display-message -p -t "$win" '#{pane_pid}' 2>/dev/null)"
    if [ -n "$pane_pid" ]; then
      for kid in $(pgrep -P "$pane_pid" 2>/dev/null); do
        case "$(ps -o command= -p "$kid" 2>/dev/null)" in
          *claude*|*nosync-wrap*) alive=1; break ;;
        esac
      done
      if [ "$alive" = 0 ]; then
        tmux send-keys -t "$win" "$cmd" Enter
        printf "relaunched claude in this folder's window -- it had exited\n" >&2
      fi
    fi
  fi

  # APPLY_SCROLLBACK_SETTINGS -- deliberately placed HERE, not at the top of the function.
  # `tmux set-option -g` does NOT reliably start a fresh server on its own: tested directly,
  # a server started with no session ever created can exit before the next command reaches
  # it (exit-empty), so global options set before any session exists can silently vanish.
  # By this point every branch above (found, moved, or newly created) guarantees a session
  # is alive, so the server cannot be reaped out from under these calls.
  #
  # Exactly the three settings the earlier ~/.tmux.conf documented as load-bearing for
  # native (swipe/wheel) scrollback -- see README.md for the mechanism and measurements.
  #
  # SCOPED AS LOCALLY AS TMUX ALLOWS. `status`, `mouse` and `history-limit` are SESSION
  # options -- targeted at "=$session" (no -g), so only sessions t-claude manages are
  # touched. An unrelated `tmux` a user starts by hand on the same server, or a session
  # someone else is running, is left at whatever it already had. Confirmed against tmux's
  # own option-scope docs (`man tmux`), not assumed from the `-g` flag's shape -- server
  # options, session options, window options and pane options are four different things
  # that all happen to accept a flag that LOOKS the same in a config file.
  #
  # `terminal-overrides` genuinely cannot be scoped narrower: it is a SERVER option (see
  # `man tmux`, "Available server options"), so setting it always affects every session on
  # this server, including ones t-claude does not manage. There is no per-session terminfo
  # override in tmux -- this is a real ceiling, not a choice made for convenience.
  #
  # `set-option` on a plain (session) option overwrites a single value, so calling it every
  # invocation is naturally idempotent. `set-option -ga` on terminal-overrides APPENDS,
  # which is not: tested directly, 4 raw invocations left 9 duplicate entries in the option
  # string -- and t-claude runs on every single launch/attach, so an unguarded append would
  # grow without bound over a tmux server's lifetime (these run for weeks). Check before
  # appending so it is idempotent for real, not just in a comment.
  # NOTE: no "=" exact-match prefix here, unlike has-session/list-windows elsewhere in this
  # script. Tested directly: `set-option -t "=$session"` fails outright with "no such
  # session: =foo", even though has-session accepts that exact syntax for the exact same
  # session -- set-option's session-target resolution does not accept it. Bare "$session"
  # works and, tested against two sessions "foo" and "foobar", correctly hits only the exact
  # match rather than affecting both -- tmux prefers an exact match when one exists.
  tmux set-option -t "$session" status off 2>/dev/null
  tmux set-option -t "$session" mouse off 2>/dev/null
  tmux set-option -t "$session" history-limit 10000 2>/dev/null
  local overrides
  overrides="$(tmux show-options -gv terminal-overrides 2>/dev/null)"
  case "$overrides" in *'smcup@:rmcup@'*) ;; *) tmux set-option -ga terminal-overrides ',*:smcup@:rmcup@' 2>/dev/null ;; esac
  case "$overrides" in *'indn@'*) ;; *) tmux set-option -ga terminal-overrides ',*:indn@' 2>/dev/null ;; esac

  tmux select-window -t "$win"
  # attach -d: detach any OTHER clients on this session first. Eternal Terminal
  # reconnects (network blips, keyboard show/hide, rotation) each leave a stale tmux
  # client behind; with the default window-size=latest the window then snaps to
  # whichever stale client last had activity -- cropping Claude to an old, smaller
  # height. Detaching others keeps exactly one client, so the window always tracks
  # the terminal you are actually looking at.
  # Replay scrollback before attaching. tmux repaints only the VISIBLE pane on attach;
  # everything that scrolled past lives in tmux's grid and is never re-emitted, so after
  # a reconnect the terminal's own scrollback starts empty and swiping up shows nothing
  # (measured: 23 of 60 lines survive a reattach -- just the one visible screen).
  # capture-pane -S - -E -1 dumps exactly the history ABOVE the visible screen, so tmux's
  # own repaint supplies the rest and nothing is duplicated (measured: 60/60, 0 dupes;
  # replaying the whole buffer instead double-paints the screen).
  # -e keeps colours. Skipped when already inside tmux (switch-client does not repaint
  # the outer terminal) and when there is no history yet.
  if [ -z "${TMUX-}" ]; then
    local hist
    hist="$(tmux display-message -p -t "$win" '#{history_size}' 2>/dev/null)"
    if [ -n "$hist" ] && [ "$hist" -gt 0 ] 2>/dev/null; then
      tmux capture-pane -p -e -S - -E -1 -t "$win" 2>/dev/null
    fi
  fi

  if [ -n "${TMUX-}" ]; then tmux switch-client -t "=$session"; else tmux attach -d -t "=$session"; fi
}
