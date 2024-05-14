# MacOS (Sonoma) dotfiles

## oh-my-zsh config setup :
1. `cd ~/Documents`
2. `git clone git@github.com:atyrode/dotfiles.git dotfiles`
3. `git checkout macos`
4. `cd dotfiles`
5. `ln -s ~/Documents/dotfiles/zsh/.zshrc ~/.zshrc`
6. `source ~/.zshrc`

## Utils :

- `prompt_yes_no()` prints first argument followed by (y/n), then reads user input and returns 0 on Y/y or 1 on N/n

## Color :

- `ok()`, `ko()`, `folder()`, `file()` prints $1 in green, red, cyan or yellow respectively

## Shell :

- `zconf` shortcuts `source ~/.zshrc`
- `z` (zoxide) replaces `cd`
- `fzf` will be used on Ctrl+R (search)

## Python :

- `python` & `pip` shortcuts `python3` & `pip3`
- `venv` is a _python venv_ manager which toggles the venv on or off in the current working directy. It will create a venv if it doesn't exist (called 'venv') and will offer to add it to .gitignore.
- Helper functions for `venv`: `check_venv()`, `create_venv()`, `check_gitignore_exists()`, `create_gitignore()`, `check_venv_in_gitignore()`, `add_venv_to_gitignore()`, `activate_venv()`, `deactivate_venv()`
