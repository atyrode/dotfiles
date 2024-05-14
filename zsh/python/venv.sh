# Shortcut to create a python venv cin the current folder if one doesn't exist already
# It it exists, acts as a toggle to activate/deactivate the env
# And ensure it's added to the .gitignore at creation
function venv() {

    ################## VARIABLES ####################

    # venv variables
    VENV_DIR="venv"
    PARENT_DIR=$(basename "$(pwd)")
    GITIGNORE=".gitignore"

    # colored representation of variables
    CVD=$(c_folder $VENV_DIR)
    CPD=$(c_folder $PARENT_DIR)
    CGI=$(c_file $GITIGNORE)

    CVENV="$CPD/$CVD"


    ################# CORE FUNCTIONS ################

    # Check if python venv exists in current folder (exists: 0, doesn't exist: 1)
    function check_venv() {
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
    function check_gitignore_exists() {
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
    function check_venv_in_gitignore() {
        if grep -q "^$VENV_DIR$" $GITIGNORE; then
            return 0
        else
            return 1
        fi
    }

    # Add venv to .gitignore
    function add_venv_to_gitignore() {
        echo $VENV_DIR >> $GITIGNORE
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


    ################## CORE LOGIC ##################

    if [[ $VIRTUAL_ENV ]]; then
        deactivate_venv
        return
    fi

    if check_venv; then
        activate_venv
        return
    fi

    # Prompt the user if they want to create a venv if it doesn't exist in current folder
    if prompt_yes_no "Do you want to create a virtual environment in $CPD?"; then

        create_venv

        # Prompt the user if they want to create a .gitignore if it doesn't exist in current folder
        if ! check_gitignore_exists; then
            if prompt_yes_no "Do you want to create a $CGI in $CPD and add $CVD to it?"; then

                create_gitignore
                add_venv_to_gitignore

            fi
        else
            # Prompt the user if they want to add the venv to the .gitignore if it's not there
            if ! check_venv_in_gitignore; then
                if prompt_yes_no "Do you want to add $CVD to $CGI in $CPD?"; then

                    add_venv_to_gitignore

                fi
            fi
        fi

        activate_venv
    fi
}