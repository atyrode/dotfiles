# Quick attach to tmux session
alias atmux="tmux attach-session -t"

# Shortcut to source ~/.zshrc
function zconf() {
    # Deactivate the current virtual environment if one is active
    if [[ $VIRTUAL_ENV ]]; then
        deactivate
        echo -e "$(c_ok Deactivated) virtual environment."
    fi

    # Clear all old aliases
    unalias -a
    echo -e "$(c_ok Cleared) old aliases."

    # Source the zsh configuration file
    source ~/.zshrc
    echo -e "$(c_ok Sourced) ~/.zshrc."
}

# Git pull with commit preview and confirmation
function zpull() {
    local force=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force=true
                shift
                ;;
            *)
                echo -e "$(c_ko Error): Unknown option '$1'"
                return 1
                ;;
        esac
    done

    # Check if we're in a git repository
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "$(c_ko Error): Not a git repository"
        return 1
    fi

    # Fetch latest changes
    echo -e "$(c_folder Fetching) latest changes..."
    git fetch

    # Check if we're up to date
    if [[ $(git status -uno) == *"up to date"* ]]; then
        echo -e "$(c_ok Up to date) with remote."
        return 0
    fi

    # Get the latest 5 commits
    echo -e "\n$(c_file Latest) commits:"
    git log -n 5 --pretty=format:"%C(yellow)%h%Creset - %C(green)%an%Creset, %C(cyan)%ar%Creset%n%s%n"

    # Skip confirmation if force flag is set
    if $force; then
        echo -e "$(c_folder Pulling) changes..."
        git pull
        echo -e "$(c_ok Success)!"
        return 0
    fi

    # Ask for confirmation
    echo -e "\n$(c_file Pull) changes? (Y/n)"
    read -r response
    response=${response:-Y}  # Default to Y if no response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo -e "$(c_folder Pulling) changes..."
        git pull
        echo -e "$(c_ok Success)!"
    else
        echo -e "$(c_file Cancelled)."
    fi
}

# Quick search for processes
pfind() {
    # Color definitions
    local CYAN='\033[0;36m'
    local BLUE='\033[0;34m'
    local YELLOW='\033[1;33m'
    local WHITE='\033[1;37m'
    local NC='\033[0m' # No Color
    
    # Parse arguments
    local search_term=""
    local show_full=false
    local kill_pid=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--full)
                show_full=true
                shift
                ;;
            -k|--kill)
                kill_pid="$2"
                shift 2
                ;;
            *)
                search_term="$1"
                shift
                ;;
        esac
    done
    
    # Store results in a temporary array
    local -a pids=()
    local -a commands=()
    local max_length=50
    local longest_cmd=0
    
    # First pass to find the longest command for table width
    while IFS= read -r line; do
        cmd=$(echo "$line" | awk '{print substr($0, index($0,$11))}')
        if ((${#cmd} > max_length)); then
            cmd_length=53
        else
            cmd_length=${#cmd}
        fi
        ((cmd_length > longest_cmd)) && longest_cmd=$cmd_length
    done < <(ps aux | grep "$search_term" | grep -v grep)
    
    # Add padding to longest_cmd to ensure even spacing (one extra for the trailing space)
    ((longest_cmd += 3))  # Changed from 2 to 3 to add one more space
    # Ensure longest_cmd is even for proper centering
    ((longest_cmd = longest_cmd % 2 == 0 ? longest_cmd : longest_cmd + 1))
    
    # Calculate exact center positions
    local cmd_center=$(( (longest_cmd - 7) / 2 ))
    local cmd_padding=$((longest_cmd + 1)) # +1 for the space after the text
    
    # Box drawing characters
    local h_line="─"
    local v_line="│"
    local tl_corner="┌"
    local tr_corner="┐"
    local bl_corner="└"
    local br_corner="┘"
    local t_connect="┬"
    local b_connect="┴"
    local l_connect="├"
    local r_connect="┤"
    local cross="┼"
    
    # Create horizontal lines of exact width
    local header_line=""
    for ((i=0; i<longest_cmd; i++)); do
        header_line+="$h_line"
    done
    
    # Counter for numbering the processes
    local i=1
    
    if $show_full; then
        # Full view with PIDs
        printf "${WHITE}${tl_corner}${h_line}${h_line}${h_line}${h_line}${h_line}${t_connect}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${t_connect}${header_line}${h_line}${tr_corner}${NC}\n"
        
        # Center-aligned headers with exact padding
        printf "${WHITE}${v_line}${YELLOW} NUM ${WHITE}${v_line}${YELLOW} PID    ${WHITE}${v_line}${YELLOW}%*s%s%*s ${WHITE}${v_line}${NC}\n" \
            $cmd_center "" "COMMAND" $((cmd_center + (7 % 2 == 0 ? 0 : 1))) ""
        
        printf "${WHITE}${l_connect}${h_line}${h_line}${h_line}${h_line}${h_line}${cross}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${cross}${header_line}${h_line}${r_connect}${NC}\n"
        
        while IFS= read -r line; do
            pid=$(echo "$line" | awk '{print $2}')
            cmd=$(echo "$line" | awk '{print substr($0, index($0,$11))}')
            
            pids+=($pid)
            commands+=("$cmd")
            
            if ((i % 2 == 0)); then
                COLOR=$BLUE
            else
                COLOR=$CYAN
            fi
            
            printf "${WHITE}${v_line}${COLOR} %-3d ${WHITE}${v_line}${COLOR} %-6s ${WHITE}${v_line}${COLOR} %-${longest_cmd}s${WHITE}${v_line}${NC}\n" \
                $i "$pid" "$cmd"
            ((i++))
        done < <(ps aux | grep "$search_term" | grep -v grep)
        
        printf "${WHITE}${bl_corner}${h_line}${h_line}${h_line}${h_line}${h_line}${b_connect}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${h_line}${b_connect}${header_line}${h_line}${br_corner}${NC}\n"
    else
        # Default view without PIDs
        printf "${WHITE}${tl_corner}${h_line}${h_line}${h_line}${h_line}${h_line}${t_connect}${header_line}${h_line}${tr_corner}${NC}\n"
        
        # Center-aligned header with exact padding
        printf "${WHITE}${v_line}${YELLOW} NUM ${WHITE}${v_line}${YELLOW}%*s%s%*s ${WHITE}${v_line}${NC}\n" \
            $cmd_center "" "COMMAND" $((cmd_center + (7 % 2 == 0 ? 0 : 1))) ""
        
        printf "${WHITE}${l_connect}${h_line}${h_line}${h_line}${h_line}${h_line}${cross}${header_line}${h_line}${r_connect}${NC}\n"
        
        while IFS= read -r line; do
            pid=$(echo "$line" | awk '{print $2}')
            cmd=$(echo "$line" | awk '{print substr($0, index($0,$11))}')
            
            pids+=($pid)
            commands+=("$cmd")
            
            if ((i % 2 == 0)); then
                COLOR=$BLUE
            else
                COLOR=$CYAN
            fi
            
            if ((${#cmd} > max_length)); then
                local cmd_start="${cmd:0:25}"
                local cmd_end="${cmd: -25}"
                printf "${WHITE}${v_line}${COLOR} %-3d ${WHITE}${v_line}${COLOR} %s${WHITE} ... ${COLOR}%s ${WHITE}${v_line}${NC}\n" \
                    $i "$cmd_start" "$cmd_end"
            else
                printf "${WHITE}${v_line}${COLOR} %-3d ${WHITE}${v_line}${COLOR} %-${longest_cmd}s${WHITE}${v_line}${NC}\n" \
                    $i "$cmd"
            fi
            ((i++))
        done < <(ps aux | grep "$search_term" | grep -v grep)
        
        # Bottom border with exact width
        printf "${WHITE}${bl_corner}${h_line}${h_line}${h_line}${h_line}${h_line}${b_connect}${header_line}${h_line}${br_corner}${NC}\n"
    fi
    
    # If we found any processes
    if ((${#pids[@]} > 0)); then
        echo -e "\n${YELLOW} Usage:${NC}"
        echo -e "${WHITE}- pfind $search_term -k NUMBER${NC} to kill a process"
        echo -e "${WHITE}- pfind $search_term -f${NC} to show full details"
    else
        echo -e "${YELLOW}No matching processes found.${NC}"
        return 1
    fi
    
    # Handle kill command if specified
    if [[ -n "$kill_pid" ]] && [[ "$kill_pid" =~ ^[0-9]+$ ]]; then
        if ((kill_pid > 0 && kill_pid <= ${#pids[@]})); then
            local pid_to_kill=${pids[$kill_pid-1]}
            echo -e "${YELLOW}Killing process $pid_to_kill (${commands[$kill_pid-1]})${NC}"
            kill $pid_to_kill
        else
            echo -e "${YELLOW}Invalid process number: $kill_pid${NC}"
            return 1
        fi
    fi
}

# Test command to create dummy processes
ptest() {
    # Create a test process with a very long command line
    python3 -c "import time; time.sleep(1000)" --arg1 value1 --arg2 value2 --arg3 value3 --arg4 value4 --arg5 value5 --very-long-argument something &
    sleep 2000 &
    sleep 3000 &
    echo -e "\033[1;32mCreated 3 test processes. Try running: pfind 'sleep|python'${NC}"
}
