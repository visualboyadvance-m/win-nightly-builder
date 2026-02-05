#!/bin/zsh

emulate posix

if [ -z "$HOME" ]; then
    export HOME="/Users/$USER"
fi

export LC_ALL=C
export TZ=UTC
export PATH=$HOME/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:$PATH

pwsh -nologo -noprofile $HOME/source/repos/win-nightly-builder/vcpkg-daily.ps1 >> $HOME/logs/vcpkg-daily.log 2>&1
