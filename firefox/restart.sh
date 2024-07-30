# Copy the dotfiles to the target firefox profile directory
sh setup.sh

# Kill the firefox process
pkill firefox

# Wait for
sleep 0.2

# Open firefox
open -a firefox

# Switch to the desktop on the right using AppleScript
osascript <<EOF
tell application "System Events"
    key down control
    key code 124
    key up control
end tell
EOF