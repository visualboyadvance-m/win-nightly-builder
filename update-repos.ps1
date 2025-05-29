$erroractionpreference = 'stop'

$env:PATH += ';' + (resolve-path '/program files/git/cmd')

$root = if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME }

write vcpkg vcpkg-binpkg-prototype vcpkg-overlay visualboyadvance-m win-nightly-builder windows-dev-guide | %{
    pushd "$root/source/repos/$_"
    git fetch --all --prune
    git pull --rebase
    popd
}
