############################################
# Terminal capability derivation
############################################

# Ghostty-family hosts still reach remote shells after the Ghostty
# retirement (#278): herdr sets TERM=xterm-ghostty in every pane
# (src/pane.rs), and sshd's default AcceptEnv only admits LANG/LC_*, so a
# forwarded COLORTERM rarely survives onto a server. The TERM value only
# ever names a terminal that renders 24-bit color, so restate the
# capability for environment-probing tools such as omp.
if [[ -z "$COLORTERM" && "$TERM" == xterm-ghostty ]]; then
  export COLORTERM=truecolor
fi
