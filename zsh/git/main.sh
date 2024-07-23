author_update() {
    local git_url=$1

    c_ok "cyan" "Starting the repository update process..."

    # Extract the repo name from the URL
    local repo_name
    repo_name=$(basename -s .git "$git_url")

    # Clone the repository
    c_ok "blue" "Cloning the repository from $git_url..."
    git clone "$git_url"

    # Change directory to the cloned repository
    c_ok "blue" "Changing directory to the cloned repository: $repo_name..."
    cd "$repo_name" || exit

    # Run the filter-repo command
    c_ok "blue" "Running git filter-repo to update email addresses..."
    git filter-repo --commit-callback '
if commit.author_email == b"alex.tyrode@outlook.fr":
    commit.author_email = b"alex.tyrode@alouette.ai"
    commit.committer_email = b"alex.tyrode@alouette.ai"
'

    # Add the remote URL
    c_ok "blue" "Adding the remote URL..."
    git remote add origin "$git_url"

    # Push the changes with force
    c_ok "blue" "Pushing the changes with force to the remote repository..."
    git push --force

    c_ok "green" "Repository update process completed successfully!"
}

