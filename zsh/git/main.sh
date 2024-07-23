git_update_author() {
    local git_url=$1

    echo -e "$(c_ok Starting) the repository update process..."

    # Extract the repo name from the URL
    local repo_name
    repo_name=$(basename -s .git "$git_url")

    # Clone the repository
    echo -e "$(c_ok Cloning) the repository from $git_url..."
    git clone "$git_url"

    # Change directory to the cloned repository
    echo -e "$(c_folder Changing) directory to the cloned repository: $repo_name..."
    cd "$repo_name" || exit

    # Run the filter-repo command
    echo -e "$(c_ok Running) git filter-repo to update email addresses..."
    git filter-repo --commit-callback '
if commit.author_email == b"alex.tyrode@outlook.fr":
    commit.author_email = b"alex.tyrode@alouette.ai"
    commit.committer_email = b"alex.tyrode@alouette.ai"
'

    # Add the remote URL
    echo -e "$(c_ok Adding) the remote URL..."
    git remote add origin "$git_url"

    # Push the changes with force
    echo -e "$(c_ok Pushing) the changes with force to the remote repository..."
    git push --force || {
        echo -e "$(c_ko Pushing) failed, setting upstream branch and retrying..."
        git push --set-upstream origin main --force
    }

    echo -e "$(c_ok Repository) update process completed successfully!"
    cd ..
}

lab() {
    # Clones from GitLab (arg = repo name)
    # https://gitlab.alouette.dev/alex.tyrode/babel.git

    local repo_name=$1

    # Clone the repository
    echo -e "$(c_ok Cloning) the repository from GitLab..."
    git clone "https://gitlab.alouette.dev/alex.tyrode/$repo_name.git"

    # Change directory to the cloned repository
    echo -e "$(c_folder Changing) directory to the cloned repository: $(c_folder $repo_name)..."
    cd "$repo_name"

    # If there's a "venv" directory, activate it
    if [[ -d "venv" ]]; then
        echo -e "A virtual environment was found ($(c_folder venv)), $(c_ok activating) it..."
        venv
    fi

    # If there's no "venv" directory, but there's a "requirements.txt" file, install the requirements
    if [[ ! -d "venv" && -f "requirements.txt" ]]; then
        echo -e "No virtual environment found, but a $(c_file requirements.txt) file was found, $(c_ok installing) the requirements..."
        venv

        # If the venv was created, install the requirements
        if [[ -d "venv" ]]; then
            pipreq
        fi
    fi
}

