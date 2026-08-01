# t-claude

A `zsh` launcher that runs [Claude Code](https://claude.com/claude-code) inside `tmux`,
organized so **one command per project** gives you persistent, reconnectable sessions —
and, on a phone over [Eternal Terminal](https://eternalterminal.dev) + Panic Prompt,
**native terminal scrollback** (swipe to scroll history, no copy-mode, no key chords).

```zsh
cd ~/my-project && t-claude Backend      # window "my-project" in session "Backend"
```

## The model

```
tmux SERVER  (one per machine)
└── SESSION      a named group of related projects — you attach/detach here (persists)
    └── WINDOW   one project (a folder) — path-keyed, so same-named folders never collide
        └── PANE  never touched by t-claude — split your own with Ctrl-b % / "
```

- **SESSION** — the name you pass (`Apps`, `Backend`, `AWS`); omit it and everything
  ungrouped shares one session, `main`.
- **WINDOW** — one per project folder, keyed by the folder *path* (a hidden
  `@tclaude_key` option), so two same-named folders never collide, and the same folder in
  two sessions is two windows.
- **`--resume <id>`** — opens a *new* window for a second conversation in the same folder,
  named `<folder>-<id>` — unless the id already IS the label (`fb4a --resume fb4a` stays
  `fb4a`); the suffix comes back automatically if two windows would otherwise read the same.
  uuid-shaped ids key windows but never appear in names.
- **`--title <label>`** — names the window (and so the terminal tab) `<label>` instead of
  the folder basename.
- **`--session-id <uuid>`** — like `--resume` for the window key, but starts the
  conversation under a chosen id (see the header comment for how a wrapper uses this).
- If a folder's window already exists in a **different** session, t-claude *moves* it to
  the session you asked for, live, without killing Claude.
- Only windows t-claude created carry `@tclaude_key`, so your **manual windows are never**
  found, reused, renamed, moved, or closed.

## Install

```zsh
curl -fsSL https://raw.githubusercontent.com/ejc3/t-claude/main/install.sh | bash
```

Or by hand:

```zsh
mkdir -p ~/.config
curl -fsSL https://raw.githubusercontent.com/ejc3/t-claude/main/t-claude.zsh -o ~/.config/t-claude.zsh
echo '[ -f ~/.config/t-claude.zsh ] && source ~/.config/t-claude.zsh' >> ~/.zshrc
# optional, for native scrollback:
sudo curl -fsSL https://raw.githubusercontent.com/ejc3/t-claude/main/nosync-wrap -o /usr/local/bin/nosync-wrap && sudo chmod +x /usr/local/bin/nosync-wrap
```

Then add the lines from [`tmux.conf.example`](tmux.conf.example) to your `~/.tmux.conf`.

## Prerequisites

| | | |
|---|---|---|
| `zsh` | required | t-claude is a zsh function sourced from `~/.zshrc`. |
| `tmux` | required | 3.4+ works; attached in **normal** client/server mode (not `tmux -CC` control mode — no iOS client speaks it). |
| `claude` | required | Claude Code on `PATH`. |
| `nosync-wrap` | optional | pty shim for native scrollback (below). Missing → bare Claude; everything else still works. |
| `~/.tmux.conf` scrollback lines | optional | the three tmux settings below, for swipe/wheel scrollback. |
| `HIST_IGNORE_SPACE` | recommended | in `~/.zshrc`, so the launch command stays out of shell history. |

## Native scrollback — how it works

Goal: a swipe (iOS) or wheel (desktop) scrolls the **terminal's own** scrollback, as if
tmux weren't there. Four things all have to be true, and each is one setting:

1. **`smcup@:rmcup@`** — tmux stays on the terminal's **primary screen** (the alternate
   screen has no scrollback).
2. **`status off`** — a single pane fills the whole terminal, so tmux scrolls the **full
   screen**, not a sub-region (terminals discard region-scrolled lines). *Splits re-break
   this — single full-screen pane only.*
3. **`indn@`** — tmux scrolls with plain **linefeeds**, never `CSI S` (some clients, e.g.
   Panic Prompt, drop `CSI S`-scrolled lines from scrollback).
4. **`nosync-wrap`** — Claude Code wraps its repaints in **synchronized-output mode**
   (`CSI ?2026h/l`). tmux buffers all grid updates while sync mode is active and emits only
   a viewport redraw, so scrolled lines never reach the terminal. `nosync-wrap` is a tiny
   pty shim that strips those sequences from Claude's output so tmux scrolls line-by-line.
   `t-claude` launches `nosync-wrap claude …` automatically when present.

**Tradeoff:** without sync mode, Claude's repaints aren't atomic, so brief tearing during
streaming is possible. **Mouse-wheel note:** on a desktop terminal the wheel may scroll the
app instead of the buffer — hold **Shift** while scrolling to force native scrollback.

## Ctrl-Z

t-claude creates the window running your **interactive shell**, then sends `claude` to it
as a **job** — so Ctrl-Z suspends Claude and `fg` resumes it. (Running Claude as the pane
command directly can't support Ctrl-Z: a pane command is a session leader, and POSIX
silently discards stop signals sent to an orphaned process group.)

## Window title & notifications

t-claude names the enclosing terminal tab after the tmux **window name** (the project label)
by asserting `set-titles on` with `set-titles-string "#{window_name}"` on its sessions and
attach views — so the tab reads `fb4a` or whatever `--title` said, and follows along when
you switch windows. This deliberately overrides the `#{pane_title}` forwarding that
tmux.conf.example ships for *non-t-claude* sessions, where the tab shows exactly what the
running program set via OSC 0. `allow-passthrough on` lets OSC 9 / OSC 777 desktop
notifications through and `monitor-bell` tracks the bell. These reach the focused pane's
terminal; a bell in a background tmux window may only raise a tmux alert rather than a
desktop notification. After the last window closes, tmux leaves the final title in place
until your shell's next prompt rewrites it.

## Usage

```zsh
cd ~/web-frontend && t-claude Apps                 # session Apps, window web-frontend
cd ~/mobile-app   && t-claude Apps                 # + window mobile-app (same session)
cd ~/api-gateway  && t-claude Backend              # session Backend, window api-gateway
cd ~/web-frontend && t-claude Apps --resume conv7  # 2nd window "web-frontend-conv7"
cd ~/fb4a         && t-claude --resume fb4a        # window (and tab) just "fb4a"
```

## License

MIT — see [LICENSE](LICENSE).
