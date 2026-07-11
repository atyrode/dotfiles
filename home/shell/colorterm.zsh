############################################
# Terminal capability derivation
############################################

# Ghostty's ssh-env integration sends COLORTERM, but sshd filters client
# variables through AcceptEnv and stock installs only accept LANG/LC_*, so
# the value rarely survives onto a server. TERM=xterm-ghostty still arrives
# (ssh-terminfo) and only ever names a terminal that renders 24-bit color,
# so restate the capability for environment-probing tools such as omp.
if [[ -z "$COLORTERM" && "$TERM" == xterm-ghostty ]]; then
  export COLORTERM=truecolor
fi
