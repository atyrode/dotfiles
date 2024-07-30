# Pompt user for yes/no input
# Returns 0 for yes, 1 for no
function prompt_yes_no() {
    local prompt_message=$1
    local answer

    while true; do
        echo -n "$prompt_message (y/n): \n> "
        read answer
        echo -n "\n"
        case $answer in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo -e "Please answer Y (yes) or N (no).";;
        esac
    done
}