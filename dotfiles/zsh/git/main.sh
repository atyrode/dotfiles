git_update_author() {
    local project_name=$1
    local owner=${2:-"atyrode"}
    local git_url="$owner/$project_name"

    echo -e "$(c_ok Starting) the repository update process..."
    
    local repo_url="https://github.com/${git_url}.git"
    local clone_url="git@github.com:${git_url}.git"

    # Clone the repository
    echo -e "$(c_ok Cloning) the repository from $repo_url..."
    git clone "$clone_url"

    # Change directory to the cloned repository
    echo -e "$(c_folder Changing) directory to the cloned repository: $project_name..."
    cd "$project_name"

    # Run the filter-repo command
    echo -e "$(c_ok Running) git filter-repo to update email addresses..."
    git filter-repo --commit-callback '
if commit.author_email == b"alex.tyrode@outlook.fr":
    commit.author_email = b"alex.tyrode@alouette.ai"
    commit.committer_email = b"alex.tyrode@alouette.ai"
'

    # # Add the remote URL
    # echo -e "$(c_ok Adding) the remote URL..."
    # git remote add origin "$repo_url"

    # Push the changes with force
    echo -e "$(c_ok Pushing) the changes with force to the remote repository..."
    git push --force || {
        echo -e "$(c_ko Pushing) failed, setting upstream branch and retrying..."
        git push --set-upstream origin main --force
    }

    echo -e "$(c_ok Repository) update process completed successfully!"
    cd ..

    # Delete the cloned repository
    echo -e "$(c_ok Deleting) the cloned repository..."
    rm -rf "$project_name"
}

lab() {
    # Clones from GitLab (arg = repo name)
    # https://gitlab.alouette.dev/alex.tyrode/babel.git

    local repo_name=$1

    # Clone the repository
    echo -e "$(c_ok Cloning) the repository from GitLab..."
    if git clone "https://gitlab.alouette.dev/alex.tyrode/$repo_name.git"; then
        echo -e "$(c_ok Successfully cloned) $repo_name."
    else
        echo -e "$(c_ko Error) while try to clone: '$repo_name'. Please check the repository name and network connection."
        return 1  # Exit the function with an error status
    fi

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

