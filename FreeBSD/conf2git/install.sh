#!/bin/sh
# install.sh — convenience installer for conf2git.sh
set -eu
PREFIX="/usr/local/scripts"
mkdir -p "$PREFIX"
install -m 0755 conf2git.sh "$PREFIX/conf2git.sh"
install -m 0644 conf2git.cfg.example "$PREFIX/conf2git.cfg.example"
echo "Installed conf2git.sh to $PREFIX/conf2git.sh"
echo "Sample config to $PREFIX/conf2git.cfg.example"
