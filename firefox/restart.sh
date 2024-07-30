# Copy the dotfiles to the target firefox profile directory
sh setup.sh

# Kill the firefox process
pkill firefox

# Wait for
sleep 0.2

# Open firefox
open -a firefox