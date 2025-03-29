################## VARIABLES ####################

# venv variables
VENV_DIR=".venv"
PARENT_DIR=""
GITIGNORE=".gitignore"

# colored representation of variables
CVD=$(c_folder $VENV_DIR)
CPD=""
CGI=$(c_file $GITIGNORE)

CVENV=""

# Required to update the venv variables to not have to source the file as reference
function update_venv_vars() {
    PARENT_DIR=$(basename "$(pwd)")
    CPD=$(c_folder $PARENT_DIR)
    CVENV="$CPD/$CVD"
}

################## SUMMARY ####################
#
# Specialized Functions:
#  ├─  venv()                           | Create/activate/deactivate a virtual environment
#  ├─  pipreq() / pipr                  | Install requirements.txt using pip or uv
#  ├─  pipfreeze() / pipf               | Freeze installed packages to requirements.txt
#  ├─  pipdel() / pipd                  | Remove all installed packages
#  └─  revenv()                         | Recreate a virtual environment
#
# Core Functions (Private):
#  ├─  _venv_exists()                   | Check if a virtual environment exists
#  ├─  _uv_available()                  | Check if uv is available
#  ├─  _ensure_uv_installed()           | Ensure uv is installed, install if needed
#  ├─  _create_venv()                   | Create a virtual environment (uses uv if available)
#  ├─  _activate_venv()                 | Activate a virtual environment
#  ├─  _venv_dir_exists()               | Check if virtual environment directory exists
#  ├─  _navigate_to_venv_parent()       | Navigate to parent directory of virtual environment
#  ├─  _deactivate_venv()               | Deactivate a virtual environment
#  ├─  _venv_is_active()                | Check if a virtual environment is active
#  ├─  _ensure_venv_active()            | Ensure a virtual environment is active
#  ├─  _ensure_venv_exists_active()     | Ensure a virtual environment exists and is active
#  ├─  _setup_gitignore()               | Setup .gitignore for the virtual environment
#  ├─  _install_requirements()          | Install requirements.txt using pip or uv
#  ├─  _freeze_requirements()           | Freeze installed packages to requirements.txt
#  └─  _remove_packages()               | Remove all installed packages
#

################# CORE FUNCTIONS (PRIVATE) ################

# Check if python venv exists in current folder (exists: 0, doesn't exist: 1)
function _venv_exists() {
    if [ -d "$VENV_DIR" ]; then
        return 0
    else
        return 1
    fi
}

# Check if uv is available (exists: 0, doesn't exist: 1)
function _uv_available() {
    if command -v uv &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Create python venv in current folder
function _create_venv() {
    if _uv_available; then
        echo -e "$(c_ok Using) uv to create virtual environment..."
        uv venv
    else
        python3 -m venv $VENV_DIR
    fi
    echo -e "$(c_ok Created) virtual environment $CVD in $CPD."
}

# Check if .gitignore exists in current folder (exists: 0, doesn't exist: 1)
function _gitignore_exists() {
    if [ -e $GITIGNORE ]; then
        return 0
    else
        return 1
    fi
}

# Create .gitignore in current folder
function _create_gitignore() {
    touch $GITIGNORE
    echo -e "$(c_ok Created) $CGI in $CPD."
}

# Check if venv is in .gitignore (is: 0, isn't: 1)
function _venv_in_gitignore() {
    if grep -q "^$VENV_DIR$" $GITIGNORE; then
        return 0
    else
        return 1
    fi
}

# Add venv to .gitignore
function _add_venv_to_gitignore() {
    echo "\n"$VENV_DIR >> $GITIGNORE
    echo -e "$(c_ok Added) $CVD to $CGI in $CPD."
}

function _activate_venv() {
    source $VENV_DIR/bin/activate
    echo -e "$(c_ok Activated) virtual environment: $CVENV"
}

# Check if virtual environment directory exists
function _venv_dir_exists() {
    if [ -d "$VIRTUAL_ENV" ]; then
        return 0
    else
        echo -e "$(c_ko Error): Virtual environment directory does not exist: $VIRTUAL_ENV"
        return 1
    fi
}

# Navigate to parent directory of virtual environment
function _navigate_to_venv_parent() {
    local venv_parent="$VIRTUAL_ENV/.."
    \cd "$venv_parent" 2>/dev/null || {
        echo -e "$(c_ko Error): Could not navigate to virtual environment parent directory."
        return 1
    }
    return 0
}

# Deactivate virtual environment
function _deactivate_venv() {
    update_venv_vars
    
    # Check if a virtual environment is active
    if ! _venv_is_active; then
        echo -e "$(c_ko Error): No virtual environment is currently active."
        return 1
    fi
    
    # Store the current CVENV value before deactivation
    local current_venv="$CVENV"
    
    # Check if we can navigate to the parent directory
    _navigate_to_venv_parent
    
    # Run the deactivate command
    deactivate
    
    # Return to the previous directory
    \cd - > /dev/null 2>&1
    
    echo -e "$(c_ko Deactivated) virtual environment: $current_venv"
    return 0
}

# Check if python venv is active (is: 0, isn't: 1)
function _venv_is_active() {
    if [[ $VIRTUAL_ENV ]]; then
        return 0
    else
        return 1
    fi
}

# Check if requirements.txt exists in current folder (exists: 0, doesn't exist: 1)
function _check_requirements_exists() {
    if [ -e "requirements.txt" ]; then
        return 0
    else
        return 1
    fi
}

# Check if uv is installed, if not install it
function _ensure_uv_installed() {
    if ! command -v uv &> /dev/null; then
        echo -e "$(c_ok Installing) uv package manager..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        
        # Verify installation succeeded
        if ! command -v uv &> /dev/null; then
            echo -e "$(c_ko Error): Failed to install uv package manager."
            return 1
        fi
        echo -e "$(c_ok Installed) uv package manager successfully."
    fi
    return 0
}

# Ensure a virtual environment is active, activate if exists
function _ensure_venv_active() {
    update_venv_vars
    
    if _venv_is_active; then
        return 0
    elif _venv_exists; then
        _activate_venv
        return $?
    else
        echo -e "$(c_ko Error): Virtual environment $CVD doesn't exist in $CPD."
        return 1
    fi
}

# Ensure a virtual environment exists and is active, create if needed
function _ensure_venv_exists_active() {
    update_venv_vars
    
    if _venv_is_active; then
        return 0
    elif _venv_exists; then
        _activate_venv
        return $?
    else
        # Create new venv if it doesn't exist
        if prompt_yes_no "Do you want to create a virtual environment in $CPD?"; then
            _create_venv
            _setup_gitignore
            _activate_venv
            return 0
        else
            return 1
        fi
    fi
}

# Setup .gitignore for the virtual environment
function _setup_gitignore() {
    update_venv_vars
    
    # Create .gitignore if it doesn't exist
    if ! _gitignore_exists; then
        if prompt_yes_no "Do you want to create a $CGI in $CPD and add $CVD to it?"; then
            _create_gitignore
            _add_venv_to_gitignore
        fi
    # Add venv to .gitignore if it's not already there
    elif ! _venv_in_gitignore; then
        if prompt_yes_no "Do you want to add $CVD to $CGI in $CPD?"; then
            _add_venv_to_gitignore
        fi
    fi
}

# Install requirements.txt using pip or uv
function _install_requirements() {
    update_venv_vars
    
    if ! _check_requirements_exists; then
        echo -e "$(c_ko Error): requirements.txt doesn't exist in $CPD."
        return 1
    fi
    
    # Check if uv is installed and install it if needed
    if _ensure_uv_installed; then
        echo -e "$(c_ok Using) uv instead of pip..."
        uv pip install -r requirements.txt
    else
        echo -e "Uv is not installed, $(c_ok falling back) to pip..."
        pip install -r requirements.txt
    fi
    
    return 0
}

# Freeze installed packages to requirements.txt
function _freeze_requirements() {
    update_venv_vars
    
    # Check if uv is installed and install it if needed
    if _ensure_uv_installed; then
        echo -e "$(c_ok Using) uv instead of pip..."
        uv pip freeze > requirements.txt
    else
        echo -e "Uv is not installed, $(c_ok falling back) to pip..."
        pip freeze > requirements.txt
    fi
    
    echo -e "$(c_ok Updated) requirements.txt in $CPD."
    return 0
}

# Remove all installed packages
function _remove_packages() {
    update_venv_vars
    
    # Check if uv is installed and install it if needed
    if _ensure_uv_installed; then
        echo -e "$(c_ok Using) uv instead of pip..."
        uv pip freeze | xargs uv pip uninstall -y
    else
        echo -e "Uv is not installed, $(c_ok falling back) to pip..."
        pip freeze | xargs pip uninstall -y
    fi
    
    echo -e "$(c_ok Removed) all installed packages in $CVD."
    return 0
}

############### SPECIALIZED FUNCTIONS ##################

# Toggle, activate, or create a python virtual environment
function venv() {
    local target_dir="${1:-$(pwd)}"
    
    # Store the original directory
    local original_dir="$(pwd)"
    
    # Change to target directory if it exists
    if [ -d "$target_dir" ]; then
        \cd "$target_dir" || {
            echo -e "$(c_ko Error): Could not change to directory: $target_dir"
            return 1
        }
    else
        echo -e "$(c_ko Error): Directory does not exist: $target_dir"
        return 1
    fi
    
    update_venv_vars
    
    # Toggle deactivate if active
    if _venv_is_active; then
        _deactivate_venv
    else
        # Otherwise ensure venv exists and is active
        _ensure_venv_exists_active
    fi
    
    # Return to original directory
    \cd "$original_dir"
}

# Install requirements.txt in the current python venv
function pipreq() {
    # Ensure venv exists and is active
    _ensure_venv_exists_active && _install_requirements
}

alias pipr="pipreq"

# Freeze installed packages to requirements.txt
function pipfreeze() {
    # Ensure venv exists and is active
    _ensure_venv_exists_active && _freeze_requirements
}

alias pipf="pipfreeze"

# Remove all installed packages in the current python venv
function pipdel() {
    # Ensure venv exists and is active
    _ensure_venv_exists_active && _remove_packages
}

alias pipd="pipdel"

# Recreate virtual environment and reinstall packages
function revenv() {
    local target_dir="${1:-$(pwd)}"
    
    # Store the original directory
    local original_dir="$(pwd)"
    
    # Change to target directory if it exists
    if [ -d "$target_dir" ]; then
        \cd "$target_dir" || {
            echo -e "$(c_ko Error): Could not change to directory: $target_dir"
            return 1
        }
    else
        echo -e "$(c_ko Error): Directory does not exist: $target_dir"
        return 1
    fi
    
    update_venv_vars
    
    # Try to deactivate if active
    _venv_is_active && _deactivate_venv
    
    # Remove existing venv if it exists
    [ -d "$VENV_DIR" ] && rm -rf $VENV_DIR
    
    # Create and activate a new venv
    _create_venv
    _activate_venv
    
    # Install requirements if they exist
    _check_requirements_exists && _install_requirements
    
    # Return to original directory
    \cd "$original_dir"
}
