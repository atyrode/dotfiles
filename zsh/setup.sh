THIS_FILE_PATH=$(
  cd $(dirname $0)
  pwd
)
install "$THIS_FILE_PATH/.zshrc" "$HOME/.zshrc"
source ~/.zshrc