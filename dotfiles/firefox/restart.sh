# Setup the firefox dotfiles
sh setup.sh

# Kill the firefox process
pkill firefox

# Wait for
sleep 0.2

# Switch to the desktop on the right using AppleScript
osascript <<EOF
tell application "System Events"
    key down control
    key code 124
    key up control
end tell
EOF

# Open firefox
open -a firefox