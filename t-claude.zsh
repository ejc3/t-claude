# t-claude [SESSION] [--resume <id>] [-- CLAUDE_ARGS...]
#
# Anything t-claude does not itself recognise is passed straight through to the `claude`
# invocation, unmodified and in order -- e.g. `t-claude --remote-control` or
# `t-claude mysession --model sonnet`. Only the FIRST bare (non-flag) argument is ever
# claimed as SESSION; every later argument, flag or not, is passthrough. This is what
# lets the managed remote-control units below (agents-start) run the exact same launcher a
# person uses interactively, just with `--remote-control` appended.
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
# THE MODEL (matches how cmux shows a tmux server: session -> left-sidebar entry, window ->
# tab across the top, pane -> split inside a tab):
#   SESSION : name it to GROUP related claudes ("apps", "backend") -- one left-sidebar entry.
#             OMIT it and everything ungrouped shares one session, "main". A session's claudes
#             are its WINDOWS (tabs).
#   WINDOW  : one per (physical folder, --resume id), keyed by that pair (hidden @tclaude_key).
#             Titled by the folder's BASENAME, extended with just enough parent path only when
#             two windows in the same session would otherwise read the same (see relabel).
#   --resume <id> : another window in the same session -- a distinct tab. Reusing an id reuses
#                   its window rather than stacking a second claude.
#   PANES   : never touched -- split your own terminal in with Ctrl-b % / ".
#   Every terminal that attaches gets its OWN throwaway GROUPED VIEW of the session, parked on
#   its window. Two terminals can then show different windows of one session at the same time
#   without mirroring, and neither detaches the other. The views self-destroy when their tab
#   closes (client-detached hook), with a start-of-run reap as backstop.
# If you pass a SESSION but this folder's claude is already open in a DIFFERENT session,
# t-claude MOVES it here live (move-window keeps claude running) -- no prompt, non-destructive.
# Safety: only windows WE create carry @tclaude_key, so manual windows are never found,
# reused, renamed, moved, or closed.

# Last k path components of PATH joined by "/", clamped to what the path has. Used to build
# window titles: 1 = basename, grown only on collision.
_tclaude_win_suffix() {
  emulate -L zsh
  local p="$1"; integer k="${2:-1}"
  local -a parts=(${(s:/:)p})
  integer n=$#parts
  (( n == 0 )) && { print -r -- "$p"; return }
  (( k < 1 )) && k=1
  (( k > n )) && k=$n
  print -r -- "${(j:/:)parts[n-k+1,n]}"
}

# Title every t-claude window in SESSION by folder basename, extending a colliding pair with
# parent path components until unique -- so "bleh" stays "bleh" until a second "bleh" shows up,
# then both become "apps/bleh", "core/bleh" (and deeper if still equal). The resume id is
# appended and also disambiguates, so only same-basename + same-resume + different-folder pairs
# ever grow. Reads @tclaude_path / @tclaude_resume (stored per window); renames only on change.
_tclaude_relabel() {
  emulate -L zsh
  local sess="$1"
  local -a ids paths resumes
  local id p r
  while IFS=$'\t' read -r id p r; do
    [ -n "$p" ] || continue
    ids+=("$id"); paths+=("$p"); resumes+=("$r")
  done < <(tmux list-windows -t "=$sess" -F $'#{window_id}\t#{@tclaude_path}\t#{@tclaude_resume}' 2>/dev/null)
  integer n=$#ids
  (( n == 0 )) && return
  integer -a kc; local -a disp; integer i j
  for (( i=1; i<=n; i++ )); do kc[$i]=1; disp[$i]="$(_tclaude_win_suffix "$paths[$i]" 1)"; done
  integer changed=1 guard=0
  while (( changed )) && (( guard < 64 )); do
    changed=0; (( guard++ ))
    for (( i=1; i<=n; i++ )); do
      for (( j=i+1; j<=n; j++ )); do
        if [[ "$disp[$i]" == "$disp[$j]" && "$resumes[$i]" == "$resumes[$j]" ]]; then
          integer ni=$(( kc[$i]+1 )) nj=$(( kc[$j]+1 ))
          local si="$(_tclaude_win_suffix "$paths[$i]" $ni)" sj="$(_tclaude_win_suffix "$paths[$j]" $nj)"
          [[ "$si" != "$disp[$i]" ]] && { kc[$i]=$ni; disp[$i]="$si"; changed=1 }
          [[ "$sj" != "$disp[$j]" ]] && { kc[$j]=$nj; disp[$j]="$sj"; changed=1 }
        fi
      done
    done
  done
  for (( i=1; i<=n; i++ )); do
    local name="$disp[$i]"
    [ -n "$resumes[$i]" ] && name="${name}-${resumes[$i]}"
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._/-' '_')"   # keep / . _ - ; no ':' (breaks targets)
    local cur; cur="$(tmux display-message -p -t "$ids[$i]" '#{window_name}' 2>/dev/null)"
    [[ "$cur" == "$name" ]] || tmux rename-window -t "$ids[$i]" "$name" 2>/dev/null
  done
}

t-claude() {
  local session="" resume="" folder base cmd key winname win explicit=0
  local -a passthrough
  # Canonical physical path (${PWD:A} resolves symlinks), NOT the logical $PWD. The window
  # identity is keyed off this, and $PWD is not stable for one directory: on a dev box
  # HOME=/home/ejc3 but ~/fbsource is a symlink to /data/users/ejc3/fbsource, so `cd ~/fbsource`
  # leaves $PWD=/home/ejc3/fbsource in one shell while another shell that reached the same dir
  # another way has $PWD=/data/users/ejc3/fbsource. Keyed off $PWD those look like two folders.
  # The physical path is the same string however you got there.
  folder="${PWD:A}"

  # Reap our own stale grouped views: sessions we made (name ends "__tcv__<digits>") with no
  # attached client, left behind if a client died without the client-detached hook firing. Two
  # guards: match only that exact suffix (so a user session merely containing "__tcv__" is never
  # touched), and only kill views older than 20s -- a view sits 0-client for a moment between
  # new-session and attach, and a concurrent launch's reap must not kill one mid-setup. Never
  # touches cmux-view-* or real sessions. `date` failing -> now=0 -> reaps nothing (safe).
  local vs now; now="$(date +%s 2>/dev/null || echo 0)"
  for vs in $(tmux list-sessions -F '#{session_name} #{session_attached} #{session_created}' 2>/dev/null | awk -v now="$now" '$1 ~ /__tcv__[0-9]+$/ && $2==0 && (now-$3) > 20 {print $1}'); do
    tmux kill-session -t "=$vs" 2>/dev/null
  done

  # SESSION, if given, must be the very first argument -- matching the usage line above. Pinning
  # it to position 1 removes an ambiguity that would otherwise exist once arbitrary flags are let
  # through: a bare token later in the list might be a flag's VALUE ("--model sonnet") rather than
  # a session name, and there is no way to tell those apart without knowing every claude flag's
  # arity -- exactly the thing passthrough exists to not need to know.
  if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
    session="$1"; shift
  fi

  # Only --resume is t-claude's own -- it names the window and keys it, so it has to be pulled
  # out and understood, not just relayed. Everything else, dash-prefixed or not, is collected in
  # order and handed to claude verbatim.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --resume=*) resume="${1#--resume=}"; shift ;;
      --resume)
        if [ -n "${2-}" ] && [ "${2#-}" = "${2-}" ]; then resume="$2"; shift 2; else shift; fi ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done

  base="${folder##*/}"; [ -z "$base" ] && base="root"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"

  # Grouping: an explicit SESSION groups related claudes under one sidebar entry; without one,
  # everything ungrouped shares "main". (No per-folder/per-resume default -- that fragmented the
  # sidebar into an entry per directory. The grouped-view attach below lets several windows of one
  # session each live in their own terminal tab without detaching, so one shared session is fine.)
  if [ -n "$session" ]; then
    explicit=1
    session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9_-' '_')"
  else
    session="main"
  fi

  key="$(printf '%s' "$folder" | cksum | awk '{print $1}')_$(printf '%s' "$resume" | cksum | awk '{print $1}')"
  winname="$base"; [ -n "$resume" ] && winname="${base}-$(printf '%s' "$resume" | tr -c 'A-Za-z0-9._-' '_')"
  # nosync-wrap strips Claude's synchronized-output-mode sequences (CSI ?2026h/l) before tmux
  # sees them so scrolled-off lines reach native scrollback. Falls back to bare claude if absent.
  # Pass --effort here rather than a claude() wrapper in ~/.zshrc: the command runs as
  # `nosync-wrap claude ...`, so the shell runs nosync-wrap and the function is skipped -- a flag
  # can't be exported, so it belongs in this command.
  local wrap=""; command -v nosync-wrap >/dev/null 2>&1 && wrap="nosync-wrap "
  local flags="--dangerously-skip-permissions --effort ultracode"
  # Each passthrough element is quoted INDIVIDUALLY (zsh's (@q)), then joined with real spaces --
  # not the whole array quoted as one blob, which collapses to a single argument. Verified
  # round-trip on values with spaces, "=", and shell metacharacters, since this string is
  # ultimately typed into a live shell via tmux send-keys.
  local extra=""
  if [ "${#passthrough[@]}" -gt 0 ]; then
    local -a qpass; qpass=("${(@q)passthrough}")
    extra=" ${qpass[*]}"
  fi
  local inner
  if [ -n "$resume" ]; then inner="${wrap}claude --resume $resume $flags$extra"
  else inner="${wrap}claude --resume $flags$extra"; fi

  # Ctrl-Z NOTE: the window runs your interactive shell and claude is sent to it as a JOB, so
  # Ctrl-Z suspends it and `fg` resumes (a pane command is a session leader whose orphaned group
  # discards stop signals). Leading space keeps the launch line out of history (HIST_IGNORE_SPACE).
  cmd=" $inner"

  # already the requested session's window?
  win=""
  if tmux has-session -t "=$session" 2>/dev/null; then
    win="$(tmux list-windows -t "=$session" -F '#{window_id} #{@tclaude_key}' 2>/dev/null | awk -v k="$key" '$2==k {print $1; exit}')"
  fi

  # explicit session, not here yet: if this folder's claude is open in another session, move it
  # here live (non-destructive -- claude keeps running).
  if [ -z "$win" ] && [ "$explicit" = 1 ]; then
    local hit osess owin ph
    # Coexist with a cmux-driven tmux: cmux's linked-view multiplexer link-windows every real
    # session's windows into a hidden "cmux-view-*" session, so a t-claude window is listed twice
    # by `list-windows -a` (its home session AND the view). Exclude view sessions here, matching
    # cmux's own invariant (all "cmux-view-*" excluded; each window has one deterministic home).
    # Without this the move below could grab the linked copy and move-window it out of the view.
    hit="$(tmux list-windows -a -F '#{session_name} #{window_id} #{@tclaude_key}' 2>/dev/null | awk -v k="$key" '$1 !~ /^cmux-view-/ && $3==k {print $1" "$2; exit}')"
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

  # Reusing a window whose claude has exited: the window now runs the shell (claude was a job), so
  # it survives that exit still carrying @tclaude_key. Look for claude among the shell's children,
  # not "any child" -- running t-claude from inside the very window it reuses makes our own command
  # substitutions children of that shell. A claude suspended with Ctrl-Z still matches, so a
  # stopped session never gets a second claude stacked on it.
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

  # Stamp the folder + resume so _tclaude_relabel can title windows by path (the @tclaude_key is
  # only cksums -- the path can't be recovered from it). Set on every run so windows created by an
  # older t-claude get labelled too. Then retitle the whole session (basename, extended on collision).
  tmux set-option -w -t "$win" @tclaude_path "$folder" 2>/dev/null
  tmux set-option -w -t "$win" @tclaude_resume "$resume" 2>/dev/null
  _tclaude_relabel "$session"

  # APPLY_SCROLLBACK_SETTINGS -- placed HERE, after a session is guaranteed alive, so a fresh
  # server can't be reaped (exit-empty) out from under `set -g`. status/mouse/history are SESSION
  # options scoped to "$session" (no -g), so only t-claude's sessions are touched. terminal-overrides
  # is a SERVER option -- it cannot be scoped narrower (no per-session terminfo override in tmux) --
  # and `-ga` APPENDS, so guard against unbounded duplicate growth over a weeks-long server. No "="
  # prefix on set-option's target: tested, it fails "no such session: =foo"; bare "$session" hits the
  # exact match when one exists.
  tmux set-option -t "$session" status off 2>/dev/null
  tmux set-option -t "$session" mouse off 2>/dev/null
  tmux set-option -t "$session" history-limit 10000 2>/dev/null
  local overrides
  overrides="$(tmux show-options -gv terminal-overrides 2>/dev/null)"
  case "$overrides" in *'smcup@:rmcup@'*) ;; *) tmux set-option -ga terminal-overrides ',*:smcup@:rmcup@' 2>/dev/null ;; esac
  case "$overrides" in *'indn@'*) ;; *) tmux set-option -ga terminal-overrides ',*:indn@' 2>/dev/null ;; esac

  # ATTACH. Inside tmux already: just move this one client to the window. From a bare terminal
  # (a new cmux tab): attach a per-invocation GROUPED VIEW parked on this window -- it shares the
  # session's windows but has its own current-window pointer, so several tabs show different windows
  # at once with no mirroring, and `attach -d` on one view can't cross-detach another. A
  # client-detached hook destroys the view when the tab closes; the start-of-run reap is the backstop.
  if [ -n "${TMUX-}" ]; then
    tmux select-window -t "$win" 2>/dev/null
    tmux switch-client -t "=$session"
  else
    # Replay scrollback above the visible screen before attaching -- tmux repaints only the visible
    # pane on attach, so native scrollback would otherwise start empty. capture-pane -S - -E -1 dumps
    # exactly the history above the screen (measured 60/60, 0 dupes); tmux's repaint supplies the rest.
    local hist
    hist="$(tmux display-message -p -t "$win" '#{history_size}' 2>/dev/null)"
    if [ -n "$hist" ] && [ "$hist" -gt 0 ] 2>/dev/null; then
      tmux capture-pane -p -e -S - -E -1 -t "$win" 2>/dev/null
    fi
    local view="${session}__tcv__${$}${RANDOM}"
    tmux new-session -d -t "=$session" -s "$view" 2>/dev/null
    tmux set-hook -t "$view" client-detached "kill-session -t $view" 2>/dev/null
    local widx; widx="$(tmux display-message -p -t "$win" '#{window_index}' 2>/dev/null)"
    [ -n "$widx" ] && tmux select-window -t "${view}:${widx}" 2>/dev/null
    tmux attach -d -t "=$view"
  fi
}
