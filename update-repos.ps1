import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

# Every checkout the builder works out of. update_git_checkout takes the lock
# that keeps this out of the way of a nightly or a manual run pulling the same
# tree, skips anything not on a clean master, and reports what git said.
echo visualboyadvance-m vcpkg vcpkg-binpkg-prototype vcpkg-overlay win-nightly-builder windows-dev-guide | %{
    update_git_checkout "$REPOS_ROOT/$_"
}
