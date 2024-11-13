#!/usr/bin/env bash

# Install Nix
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# Start a new shell and check the Nix version in that shell
exec $SHELL -c "nix --version"
