# Terminal working-directory metadata
############################################

# Rio's built-in file-path hints resolve relative paths from OSC 7 metadata.
# Emit it at every prompt for Rio and other terminals that understand the
# standard sequence. Keep this shell-owned rather than Rio-owned so cwd changes
# made by zsh remain authoritative through the terminal stack.
autoload -Uz add-zsh-hook

_atyrode_report_cwd() {
  local encoded_path=${PWD//\%/%25}
  encoded_path=${encoded_path// /%20}
  encoded_path=${encoded_path//\#/%23}
  encoded_path=${encoded_path//\?/%3F}
  printf '\e]7;file://%s%s\e\\' "$HOST" "$encoded_path"
}

add-zsh-hook precmd _atyrode_report_cwd
