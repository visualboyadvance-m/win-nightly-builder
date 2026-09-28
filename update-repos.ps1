import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

# Every checkout the builder works out of. update_git_checkout takes the lock
# that keeps this out of the way of a nightly or a manual run pulling the same
# tree, skips anything not on a clean master, and reports what git said.
#
# A checkout a run is working out of is left where it is.
#
# This is hourly and a nightly runs for hours, so without the check a pull
# lands in the middle of one: the ports tree moves, a host tool that was
# current when the run refreshed it goes stale, and rebuilding it takes every
# dependent across every triplet with it, under whatever single environment the
# pass that noticed happens to have. vcpkg-daily holds the "inuse" lock for as
# long as it is building.
#
# Asked for without waiting. Blocking here would stall the hourly task behind a
# nightly for hours, and there is nothing to be gained by it: skipping means
# the pull happens on the next hour instead, which is what this schedule is
# for.
echo visualboyadvance-m vcpkg vcpkg-binpkg-prototype vcpkg-overlay win-nightly-builder windows-dev-guide | %{
    $path = "$REPOS_ROOT/$_"
    $held = acquire_git_lock $path -timeout_seconds 0 -kind 'inuse'

    if (-not $held) {
        "Skipping $($_): a run is working out of it."
        return
    }

    try     { update_git_checkout $path }
    finally { release_git_lock $held }
}
