# Narrow machine-local escape hatch for interactive behavior that cannot be
# expressed portably. Project policy, runtimes, and shared tools do not belong
# here. This file is never loaded by non-interactive shells.
if [[ -o interactive && -r "$HOME/.config/zsh/local.zsh" ]]; then
  source "$HOME/.config/zsh/local.zsh"
fi
