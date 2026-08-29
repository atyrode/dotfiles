# Terminal working-directory metadata
############################################

# Any terminal that understands the standard OSC 7 sequence resolves relative
# file-path hints from this metadata, so emit it at every prompt. Keep the
# emission shell-owned rather than terminal-owned so cwd changes made by zsh
# stay authoritative through the terminal stack.
autoload -Uz add-zsh-hook

_atyrode_report_cwd() {
  local encoded_path=${PWD//\%/%25}
  encoded_path=${encoded_path// /%20}
  encoded_path=${encoded_path//\#/%23}
  encoded_path=${encoded_path//\?/%3F}
  printf '\e]7;file://%s%s\e\\' "$HOST" "$encoded_path"
}

add-zsh-hook precmd _atyrode_report_cwd
