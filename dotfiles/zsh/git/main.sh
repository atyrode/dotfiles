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

backlab() {
    # Backups a GitLab repository with embedded LFS objects (arg = repo name)
    # Includes colored messages for better readability

    local repo_name=$1

    if [[ -z "$repo_name" ]]; then
        echo -e "$(c_ko 'Error'): No repository name provided."
        echo "Usage: backlab <repository-name>"
        return 1
    fi

    local repo_url="https://gitlab.alouette.dev/alex.tyrode/$repo_name.git"
    local backup_dir="$repo_name-backup"
    local bundle_name="$repo_name.bundle"

    # Clone the repository using --mirror
    echo -e "$(c_ok 'Cloning') the repository with --mirror for a complete backup..."
    if git clone --mirror "$repo_url" "$backup_dir"; then
        echo -e "$(c_ok 'Successfully cloned') $(c_file $repo_name) into $(c_folder $backup_dir)."
    else
        echo -e "$(c_ko 'Error') while trying to clone '$(c_file $repo_name)'. Please check the repository name and network connection."
        return 1
    fi

    # Change directory to the cloned repository
    echo -e "$(c_folder 'Changing') directory to the cloned repository: $(c_folder $backup_dir)..."
    cd "$backup_dir"

    # Fetch all Git LFS objects if LFS is used
    if git lfs ls-files &> /dev/null; then
        echo -e "$(c_ok 'Git LFS detected'), fetching all LFS objects..."
        if git lfs fetch --all; then
            echo -e "$(c_ok 'Successfully fetched') all Git LFS objects."
        else
            echo -e "$(c_ko 'Error') while fetching Git LFS objects."
            return 1
        fi

        # Migrate LFS objects back into Git
        echo -e "$(c_ok 'Embedding') Git LFS objects into Git history..."
        if git lfs migrate export --include="*"; then
            echo -e "$(c_ok 'Successfully embedded') LFS objects into Git history."
        else
            echo -e "$(c_ko 'Error') embedding LFS objects into Git history."
            return 1
        fi
    else
        echo -e "No Git LFS objects detected."
    fi

    # Create a Git bundle
    echo -e "$(c_ok 'Creating') a Git bundle for the repository..."
    if git bundle create "../$bundle_name" --all; then
        echo -e "$(c_ok 'Successfully created') the bundle: $(c_file $bundle_name)."
    else
        echo -e "$(c_ko 'Error') while creating the Git bundle."
        return 1
    fi

    # Navigate back and clean up if desired
    cd ..

    # Optionally remove the mirror clone if not needed
    echo -e "$(c_ok 'Cleaning up') the mirror clone..."
    rm -rf "$backup_dir"

    echo -e "$(c_ok 'Backup complete'). The repository has been bundled into $(c_file $bundle_name)."
}

unbacklab() {
    # Restores a repository from a Git bundle with embedded LFS objects (arg = repo name)
    # Includes colored messages for better readability

    local repo_name=$1

    if [[ -z "$repo_name" ]]; then
        echo -e "$(c_ko 'Error'): No repository name provided."
        echo "Usage: unbacklab <repository-name>"
        return 1
    fi

    local bundle_name="$repo_name.bundle"

    # Check if the bundle file exists
    if [[ ! -f "$bundle_name" ]]; then
        echo -e "$(c_ko 'Error'): Bundle file $(c_file $bundle_name) not found."
        return 1
    fi

    # Clone the repository from the bundle
    echo -e "$(c_ok 'Cloning') the repository from the bundle..."
    if git clone "$bundle_name" "$repo_name"; then
        echo -e "$(c_ok 'Successfully cloned') $(c_file $repo_name) from the bundle."
    else
        echo -e "$(c_ko 'Error') while cloning from the bundle."
        return 1
    fi

    # Change directory to the cloned repository
    echo -e "$(c_folder 'Changing') directory to the cloned repository: $(c_folder $repo_name)..."
    cd "$repo_name"

    # Since LFS objects are embedded, no need to handle LFS separately
    echo -e "$(c_ok 'Restoration complete'). The repository is ready to use."
}