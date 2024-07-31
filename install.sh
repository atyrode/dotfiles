#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e 

# Install Nix
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

nix --version