# t-claude [SESSION] [--resume <id> | --session-id <uuid>] [--title <label>] [CLAUDE_ARGS...]
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
# Scope: status/mouse/history/set-titles are SESSION options asserted on t-claude's own
# session (including a pre-existing session you named -- share a session with t-claude and
# it manages these there); terminal-overrides is a SERVER option, so that one does apply to
# the whole server. A hand-written ~/.tmux.conf can still coexist: it loads once at server
# start, t-claude's settings are asserted after and win regardless of invocation order, so a
# stray or outdated config file can no longer silently break scrollback. Note set-titles
# pins the enclosing terminal's tab to the WINDOW NAME while attached (and tmux leaves the
# last title behind after detach until the shell's next prompt rewrites it).
#
# THE MODEL (matches how cmux shows a tmux server: session -> left-sidebar entry, window ->
# tab across the top, pane -> split inside a tab):
#   SESSION : name it to GROUP related claudes ("apps", "backend") -- one left-sidebar entry.
#             OMIT it and everything ungrouped shares one session, "main". A session's claudes
#             are its WINDOWS (tabs).
#   WINDOW  : one per (physical folder, session id), keyed by that pair (hidden @tclaude_key).
#             Titled by the folder's BASENAME, extended with just enough parent path only when
#             two windows in the same session would otherwise read the same (see relabel).
#             Closes when claude exits cleanly (/exit) -- no empty shell tab left behind; a
#             crash or Ctrl-Z keeps the shell so you can read the error or fg.
#   --resume <id> : another window in the same session -- a distinct tab. Reusing an id reuses
#                   its window rather than stacking a second claude.
#   --title <label> : window/tab label override -- the window shows <label> instead of the
#                   folder basename. For grouping several named claudes ("foo-project",
#                   "blah-project") in one session when their folders would read alike.
#   --session-id <uuid> : like --resume for the window key, but the inner claude gets
#                   `--session-id` -- it STARTS a conversation under a chosen id instead of
#                   reopening one. A wrapper can hand out a deterministic id on the first run
#                   and `--resume` the same id ever after; both runs land in the same window.
#                   uuid-shaped ids are kept out of window titles (they key, they don't label).
#   PANES   : never touched -- split your own terminal in with Ctrl-b % / ".
#   Every terminal that attaches gets its OWN throwaway GROUPED VIEW of the session, parked on
#   its window. Two terminals can then show different windows of one session at the same time
#   without mirroring, and neither detaches the other. The views self-destroy when their tab
#   closes (client-detached hook), with a start-of-run reap as backstop.
# If you pass a SESSION but this folder's claude is already open in a DIFFERENT session,
# t-claude MOVES it here live (move-window keeps claude running) -- no prompt, non-destructive.
# Safety: only windows WE create carry @tclaude_key, so manual windows are never found,
# reused, renamed, moved, or closed.

# True when $1 is uuid-shaped: 36 chars, hex plus exactly four dashes. Used to keep machine
# ids out of window titles -- a uuid disambiguates the window KEY, but as a label it's noise
# ("fbcode" beats "fbcode-2f3a4b5c-..."). Short human ids ("my-diffs") still show.
_tclaude_is_uuid() {
  [ "${#1}" -eq 36 ] || return 1
  [ -z "$(printf '%s' "$1" | tr -d '0-9a-fA-F-')" ] || return 1
  [ "$(printf '%s' "$1" | tr -cd '-' | wc -c | tr -d ' ')" -eq 4 ]
}

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

# Title every t-claude window in SESSION. The label is the explicit --title when one was
# given, else the folder basename, path-extended only when two windows would otherwise read
# the same. A human --resume id is appended when it adds information: skipped when it IS the
# label (fb4a stays fb4a), but brought back as the tiebreaker if that skip would leave two
# windows identically named. uuid-shaped ids never label. All values are sanitized with the
# same class the creation path uses, so the two naming sites agree.
_tclaude_relabel() {
  emulate -L zsh
  local sess="$1"
  local -a ids paths resumes titles parts
  local line
  for line in "${(@f)$(tmux list-windows -t "=$sess" -F $'#{window_id}\t#{@tclaude_path}\t#{@tclaude_resume}\t#{@tclaude_title}' 2>/dev/null)}"; do
    # (@ps:\t:) keeps EMPTY fields; an IFS-tab read collapses adjacent tabs and shifts a
    # title into the resume slot when @tclaude_resume is empty
    parts=("${(@ps:\t:)line}")
    [ -n "${parts[2]-}" ] || continue
    ids+=("$parts[1]"); paths+=("$parts[2]")
    resumes+=("$(printf '%s' "${parts[3]-}" | tr -c 'A-Za-z0-9._-' '_')")
    titles+=("$(printf '%s' "${parts[4]-}" | tr -c 'A-Za-z0-9._-' '_')")
  done
  integer n=$#ids
  (( n == 0 )) && return
  local -a kc disp suf
  integer i j
  for (( i=1; i<=n; i++ )); do
    kc[i]=1
    if [ -n "$titles[$i]" ]; then disp[i]="$titles[$i]"
    else disp[i]="$(printf '%s' "$(_tclaude_win_suffix "$paths[$i]" 1)" | tr -c 'A-Za-z0-9._/-' '_')"; fi
    if [ -n "$resumes[$i]" ] && ! _tclaude_is_uuid "$resumes[$i]" && [ "$resumes[$i]" != "$disp[$i]" ]; then
      suf[i]="$resumes[$i]"
    else
      suf[i]=""
    fi
  done
  integer changed=1 guard=0
  while (( changed )) && (( guard < 64 )); do
    changed=0; (( guard++ ))
    for (( i=1; i<=n; i++ )); do
      for (( j=i+1; j<=n; j++ )); do
        [[ "$disp[$i]${suf[$i]:+-$suf[$i]}" == "$disp[$j]${suf[$j]:+-$suf[$j]}" ]] || continue
        if [[ "$resumes[$i]" != "$resumes[$j]" ]]; then
          # differing ids separate the pair even when an id equals the label: a plain fb4a
          # window and a --resume fb4a window become fb4a and fb4a-fb4a. uuid ids stay out
          # of titles normally, but an otherwise-unbreakable tie (two titled windows with
          # the same label) gets the first 8 characters as the tiebreaker.
          local ri="$resumes[$i]" rj="$resumes[$j]"
          _tclaude_is_uuid "$ri" && ri="${ri[1,8]}"
          _tclaude_is_uuid "$rj" && rj="${rj[1,8]}"
          if [ -n "$ri" ] && [ "$suf[$i]" != "$ri" ]; then suf[i]="$ri"; changed=1; fi
          if [ -n "$rj" ] && [ "$suf[$j]" != "$rj" ]; then suf[j]="$rj"; changed=1; fi
        else
          integer ni=$(( kc[i]+1 )) nj=$(( kc[j]+1 ))
          if [ -z "$titles[$i]" ]; then
            local si="$(printf '%s' "$(_tclaude_win_suffix "$paths[$i]" $ni)" | tr -c 'A-Za-z0-9._/-' '_')"
            [[ "$si" != "$disp[$i]" ]] && { kc[i]=$ni; disp[i]="$si"; changed=1 }
          fi
          if [ -z "$titles[$j]" ]; then
            local sj="$(printf '%s' "$(_tclaude_win_suffix "$paths[$j]" $nj)" | tr -c 'A-Za-z0-9._/-' '_')"
            [[ "$sj" != "$disp[$j]" ]] && { kc[j]=$nj; disp[j]="$sj"; changed=1 }
          fi
        fi
      done
    done
  done
  for (( i=1; i<=n; i++ )); do
    local name="$disp[$i]${suf[$i]:+-$suf[$i]}"
    local cur; cur="$(tmux display-message -p -t "$ids[$i]" '#{window_name}' 2>/dev/null)"
    [[ "$cur" == "$name" ]] || tmux rename-window -t "$ids[$i]" "$name" 2>/dev/null
  done
}

t-claude() {
  local session="" resume="" sid="" title="" folder base cmd key winname win explicit=0
  local -a passthrough
  # Canonical physical path (${PWD:A} resolves symlinks), NOT the logical $PWD. The window
  # identity is keyed off this, and $PWD is not stable for one directory: on a dev box
  # HOME=/home/ejc3 but ~/fbsource is a symlink to /data/users/ejc3/fbsource, so `cd ~/fbsource`
  # leaves $PWD=/home/ejc3/fbsource in one shell while another shell that reached the same dir
  # another way has $PWD=/data/users/ejc3/fbsource. Keyed off $PWD those look like two folders.
  # The physical path is the same string however you got there.
  folder="${PWD:A}"

  # Self-heal hooks on EXISTING views: a shell that sourced an older t-claude writes an
  # older window-unlinked hook onto the views it creates, and one stale view in the group
  # can misbehave for every tab (the kill-session generation detached sibling clients).
  # Every launch rewrites live views' hooks to the current generation, so upgrades take
  # effect without every shell re-sourcing.
  local hv hh hw
  for hv in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '__tcv__' 2>/dev/null); do
    hh="$(tmux show-hooks -t "$hv" 2>/dev/null | grep -m1 window-unlinked)"
    [ -n "$hh" ] || continue
    hw="${${hh#*grep -qx \'}%%\'*}"
    case "$hw" in
      @*) tmux set-hook -t "$hv" window-unlinked \
            "run-shell -b \"tmux list-windows -a -F '##{window_id}' | grep -qx '$hw' || tmux detach-client -s '$hv' 2>/dev/null || true\"" 2>/dev/null ;;
    esac
  done

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

  # Only --resume and --session-id are t-claude's own -- they name the window and key it, so
  # they have to be pulled out and understood, not just relayed. Everything else, dash-prefixed
  # or not, is collected in order and handed to claude verbatim.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --resume=*) resume="${1#--resume=}"; shift ;;
      --resume)
        if [ -n "${2-}" ] && [ "${2#-}" = "${2-}" ]; then resume="$2"; shift 2; else shift; fi ;;
      --session-id=*) sid="${1#--session-id=}"; shift ;;
      --session-id)
        if [ -n "${2-}" ] && [ "${2#-}" = "${2-}" ]; then sid="$2"; shift 2; else shift; fi ;;
      --title=*) title="${1#--title=}"; shift ;;
      --title)
        if [ -n "${2-}" ] && [ "${2#-}" = "${2-}" ]; then title="$2"; shift 2; else shift; fi ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done

  # One id drives the window key and title: --resume wins if both were given. They differ only
  # in which flag the inner claude gets, so a first run under --session-id and every later run
  # under --resume with the same id share one window.
  local tcid="$resume"; [ -z "$tcid" ] && tcid="$sid"

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

  key="$(printf '%s' "$folder" | cksum | awk '{print $1}')_$(printf '%s' "$tcid" | cksum | awk '{print $1}')"
  # --title labels the window instead of the folder basename (relabel keeps it verbatim).
  [ -n "$title" ] && title="$(printf '%s' "$title" | tr -c 'A-Za-z0-9._-' '_')"
  winname="${title:-$base}"
  # Append a human id (e.g. --resume my-diffs) unless it IS the label already --
  # "fb4a --resume fb4a" should read "fb4a", not "fb4a-fb4a".
  if [ -n "$tcid" ] && ! _tclaude_is_uuid "$tcid"; then
    local tcid_s; tcid_s="$(printf '%s' "$tcid" | tr -c 'A-Za-z0-9._-' '_')"
    [ "$tcid_s" != "$winname" ] && winname="${winname}-${tcid_s}"
  fi
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
  if [ -n "$resume" ]; then inner="${wrap}claude --resume ${(q)resume} $flags$extra"
  elif [ -n "$sid" ]; then inner="${wrap}claude --session-id ${(q)sid} $flags$extra"
  else inner="${wrap}claude --resume $flags$extra"; fi

  # Ctrl-Z NOTE: the window runs your interactive shell and claude is sent to it as a JOB, so
  # Ctrl-Z suspends it and `fg` resumes (a pane command is a session leader whose orphaned group
  # discards stop signals). Leading space keeps the launch line out of history (HIST_IGNORE_SPACE).
  #
  # `&& exit` closes the window when claude exits CLEANLY (/exit) instead of leaving an empty
  # shell tab behind. It stays out of the way everywhere else: Ctrl-Z makes the job's status
  # 148, so `exit` is skipped and the shell is there for fg; a crash exits nonzero, so the
  # shell (and the error) stay visible too.
  cmd=" $inner && exit"

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
    if [ -z "$win" ]; then
      # never fall through with an empty target: tmux resolves it to the CURRENT window and
      # the launch line (ending "&& exit") would be typed into whatever the user is doing
      printf "t-claude: could not create a window in session '%s'\n" "$session" >&2
      return 1
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
      local kcmd
      for kid in $(pgrep -P "$pane_pid" 2>/dev/null); do
        kcmd="$(ps -o command= -p "$kid" 2>/dev/null)"
        # match the job we launch (claude, or the nosync-wrap shim running claude) -- NOT any
        # argv that merely mentions a path with "claude" in it (less ~/src/t-claude/... is
        # not a running claude)
        case "${${kcmd%% *}:t}" in claude) alive=1; break ;; esac
        case "$kcmd" in *"nosync-wrap claude"*) alive=1; break ;; esac
      done
      if [ "$alive" = 0 ]; then
        # A killed claude leaves its terminal modes latched on the pane -- focus-reporting
        # (DECSET 1004) in particular. The shell at the prompt doesn't understand focus
        # escapes, so the next client attach can splice ^[[I/^[[O into the line we are about
        # to type and the relaunch never executes (caught by acceptance testing: the line sat
        # as " nosync-^[[I^[[O"). Reset the pane's terminal state, clear the line, then type.
        tmux send-keys -R -t "$win" '' 2>/dev/null
        tmux send-keys -t "$win" C-u 2>/dev/null
        tmux send-keys -t "$win" "$cmd" Enter
        printf "relaunched claude in this folder's window -- it had exited\n" >&2
      fi
    fi
  fi

  # Stamp the folder + resume so _tclaude_relabel can title windows by path (the @tclaude_key is
  # only cksums -- the path can't be recovered from it). Set on every run so windows created by an
  # older t-claude get labelled too. Then retitle the whole session (basename, extended on collision).
  tmux set-option -w -t "$win" @tclaude_path "$folder" 2>/dev/null
  tmux set-option -w -t "$win" @tclaude_resume "$tcid" 2>/dev/null
  if [ -n "$title" ]; then tmux set-option -w -t "$win" @tclaude_title "$title" 2>/dev/null
  else tmux set-option -w -u -t "$win" @tclaude_title 2>/dev/null; fi
  _tclaude_relabel "$session"

  # APPLY_SCROLLBACK_SETTINGS -- placed HERE, after a session is guaranteed alive, so a fresh
  # server can't be reaped (exit-empty) out from under `set -g`. status/mouse/history are SESSION
  # options scoped to "$session" (no -g), so only t-claude's sessions are touched. terminal-overrides
  # is a SERVER option -- it cannot be scoped narrower (no per-session terminfo override in tmux) --
  # and `-ga` APPENDS, so guard against unbounded duplicate growth over a weeks-long server. No "="
  # prefix on set-option's target: tested, it fails "no such session: =foo"; bare "$session" hits the
  # exact match when one exists.
  tmux set-option -t "$session" status off 2>/dev/null
  tmux set-option -t "$session" set-titles on 2>/dev/null
  tmux set-option -t "$session" set-titles-string "#{window_name}" 2>/dev/null
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
  local widx
  widx="$(tmux list-windows -t "=$session" -F $'#{window_id}\t#{window_index}' 2>/dev/null | awk -F'\t' -v w="$win" '$1==w{print $2; exit}')"
  if [ -n "${TMUX-}" ]; then
    tmux switch-client -t "=$session"
    [ -n "$widx" ] && tmux select-window -t "=${session}:${widx}" 2>/dev/null
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
    # This view exists to show ONE window. When that window ceases to exist (claude /exits
    # and the launch line closes it), kill the view so the client detaches all the way back
    # to the shell -- without this, tmux parks the client on a neighboring window instead.
    # A window MOVED to another session still exists server-wide, so regrouping does not
    # detach viewers. The existence check is list-windows|grep: display-message accepts a
    # dead window id without complaint (measured on 3.7b), so it cannot be the predicate;
    # ## keeps the format literal through hook-time expansion.
    # The command must NEVER exit nonzero or print (a failed run-shell becomes a "returned
    # 1" message pane on nearby clients, and window-unlinked fires more than once per
    # close). And it must DETACH the client rather than kill the view: killing a grouped
    # session out from under its live client detaches the group's OTHER clients too
    # (measured on 3.7b -- one /exit closed every tab). Detaching is ripple-free, and the
    # client-detached hook above then reaps the view once it is clientless.
    tmux set-hook -t "$view" window-unlinked \
      "run-shell -b \"tmux list-windows -a -F '##{window_id}' | grep -qx '$win' || tmux detach-client -s '$view' 2>/dev/null || true\"" 2>/dev/null
    # A grouped session shares windows but has its OWN session options, so the status-off
    # applied to the real session doesn't reach the view -- without this, a host with no
    # ~/.tmux.conf shows tmux's default green status bar in every t-claude terminal.
    tmux set-option -t "$view" status off 2>/dev/null
    # Carry the tab label out to the enclosing terminal: the attached client's title becomes
    # the window name (the --title label when one was given), so the cmux/ghostty window is
    # named after the claude session it is showing.
    tmux set-option -t "$view" set-titles on 2>/dev/null
    tmux set-option -t "$view" set-titles-string "#{window_name}" 2>/dev/null
    tmux set-hook -t "$view" client-detached "kill-session -t $view" 2>/dev/null
    [ -n "$widx" ] && tmux select-window -t "${view}:${widx}" 2>/dev/null
    tmux attach -d -t "=$view"
  fi
}
