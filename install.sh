#!/usr/bin/env bash
# Install t-claude + nosync-wrap and wire the zsh hook.
#   curl -fsSL https://raw.githubusercontent.com/ejc3/t-claude/main/install.sh | bash
set -euo pipefail
RAW="https://raw.githubusercontent.com/ejc3/t-claude/main"

mkdir -p "$HOME/.config"
curl -fsSL "$RAW/t-claude.zsh" -o "$HOME/.config/t-claude.zsh"
echo "installed ~/.config/t-claude.zsh"

# nosync-wrap is optional but needed for native scrollback; install to a user-writable
# dir if /usr/local/bin needs sudo.
if curl -fsSL "$RAW/nosync-wrap" -o /tmp/nosync-wrap; then
  if [ -w /usr/local/bin ]; then install -m755 /tmp/nosync-wrap /usr/local/bin/nosync-wrap
  else mkdir -p "$HOME/.local/bin"; install -m755 /tmp/nosync-wrap "$HOME/.local/bin/nosync-wrap"; fi
  rm -f /tmp/nosync-wrap
  echo "installed nosync-wrap"
fi

# Source line in ~/.zshrc (idempotent).
LINE='[ -f ~/.config/t-claude.zsh ] && source ~/.config/t-claude.zsh'
grep -qF "$LINE" "$HOME/.zshrc" 2>/dev/null || echo "$LINE" >> "$HOME/.zshrc"
echo "done. add the tmux.conf.example lines to ~/.tmux.conf for native scrollback."
