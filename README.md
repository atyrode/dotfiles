# Installation

## 1. Get NixOS

### Windows

Follow the instructions for: [NixOS for WSL](https://github.com/nix-community/NixOS-WSL?tab=readme-ov-file)


## 2. Get Home Manager

```
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --update
nix-shell '<home-manager>' -A install
```

## 3. Clone this repository

```
git clone https://github.com/atyrode/dotfiles nixfiles
cd nixfiles
```

## 4. Switch config

At the end of Home Manager's installation, it will tell you where it wrote the default config,
create a symbolic link of this repository's `home.nix` pointing to that path.

Example:

```
rm -rf ~/.config/home-manager
ln -s $(pwd)/home-manager ~/.config/home-manager
```