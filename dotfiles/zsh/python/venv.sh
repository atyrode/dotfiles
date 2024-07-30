################## VARIABLES ####################

# venv variables
VENV_DIR="venv"
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

################# CORE FUNCTIONS ################

# Check if python venv exists in current folder (exists: 0, doesn't exist: 1)
function venv_exists() {
    if [ -d "venv" ]; then
        return 0
    else
        return 1
    fi
}

# Create python venv in current folder
function create_venv() {
    python3 -m venv $VENV_DIR
    echo -e "$(c_ok Created) virtual environment $CVD in $CPD."
}

# Check if .gitignore exists in current folder (exists: 0, doesn't exist: 1)
function gitignore_exists() {
    if [ -e $GITIGNORE ]; then
        return 0
    else
        return 1
    fi
}

# Create .gitignore in current folder
function create_gitignore() {
    touch $GITIGNORE
    echo -e "$(c_ok Created) $CGI in $CPD."
}

# Check if venv is in .gitignore (is: 0, isn't: 1)
function venv_in_gitignore() {
    if grep -q "^$VENV_DIR$" $GITIGNORE; then
        return 0
    else
        return 1
    fi
}

# Add venv to .gitignore
function add_venv_to_gitignore() {
    echo "\n"$VENV_DIR >> $GITIGNORE
    echo -e "$(c_ok Added) $CVD to $CGI in $CPD."
}

function activate_venv() {
    source $VENV_DIR/bin/activate
    echo -e "$(c_ok Activated) virtual environment: $CVENV"
}

function deactivate_venv() {
    deactivate
    echo -e "$(c_ko Deactivated) virtual environment: $CVENV"
}

# Check if python venv is active (is: 0, isn't: 1)
function venv_is_active() {
    if [[ $VIRTUAL_ENV ]]; then
        return 0
    else
        return 1
    fi
}

# Check if requirements.txt exists in current folder (exists: 0, doesn't exist: 1)
function check_requirements_exists() {
    if [ -e "requirements.txt" ]; then
        return 0
    else
        return 1
    fi
}

############### SPECIALIZED FUNCTIONS ##################

# Shortcut to create a python venv cin the current folder if one doesn't exist already
# It it exists, acts as a toggle to activate/deactivate the env
# And ensure it's added to the .gitignore at creation
function venv() {

    update_venv_vars

    if venv_is_active; then
        deactivate_venv
        return
    elif venv_exists; then
        activate_venv
        return
    fi

    # Prompt the user if they want to create a venv if it doesn't exist in current folder
    if prompt_yes_no "Do you want to create a virtual environment in $CPD?"; then

        create_venv

        # Prompt the user if they want to create a .gitignore if it doesn't exist in current folder
        if ! gitignore_exists; then
            if prompt_yes_no "Do you want to create a $CGI in $CPD and add $CVD to it?"; then

                create_gitignore
                add_venv_to_gitignore

            fi
        else
            # Prompt the user if they want to add the venv to the .gitignore if it's not there
            if ! venv_in_gitignore; then
                if prompt_yes_no "Do you want to add $CVD to $CGI in $CPD?"; then

                    add_venv_to_gitignore

                fi
            fi
        fi

        activate_venv
    fi
}

# Shortcut to install requirements.txt in the current python venv
function pipreq() {

    update_venv_vars

    if ! venv_is_active; then 
        venv

        if ! venv_exists; then
            echo -e "$(c_ko Error): virtual environment $CVD doesn't exist in $CPD, won't install pip requirements out of it."
            return
        fi
    fi

    pip install -r requirements.txt
}