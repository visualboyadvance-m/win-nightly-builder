import-module -force $psscriptroot/vbam-builder.psm1

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$build_triplets = get-triplets @args

$repo_path = join-path $REPOS_ROOT visualboyadvance-m

if (-not (test-path $repo_path)) {
    pushd $REPOS_ROOT

    git clone git@github.com:visualboyadvance-m/visualboyadvance-m

    popd
}

pushd $repo_path

git pull --rebase
git submodule update --init --recursive

popd

foreach ($triplet in $build_triplets) {
    foreach ($tk in $triplet.toolkits) {
        setup_build_env $triplet $tk

        # An Android triplet takes the cross list; GTK and the X11/Wayland
        # Vulkan loader the host list carries do not build for it.
        $ports = get_dep_ports $triplet

        vcpkg --triplet $triplet install --no-binarycaching --recurse --keep-going $ports --allow-unsupported
        vcpkg --triplet $triplet upgrade --no-binarycaching ($ports -replace '\[[^\]]+\]','') --no-dry-run --allow-unsupported

        $build_dir = join-path $repo_path build-$triplet

        ni -it dir $build_dir   -ea ignore | out-null
        ri -r -fo  $build_dir/* -ea ignore

        pushd $build_dir

        cmake .. -DCMAKE_BUILD_TYPE=Release -DVCPKG_TARGET_TRIPLET="$triplet" -DUPSTREAM_RELEASE=TRUE -G Ninja
        ninja

        popd
    }
}

# The sweep that catches what went out of date behind the named ports above:
# the transitive dependencies nothing in $DEP_PORTS asks for by name.
#
# A bare `vcpkg upgrade` did this in one command, but an upgrade with no port
# named ignores --triplet and plans a rebuild of every triplet in the installed
# tree at once, so all of them built under whichever single environment
# happened to be set. The mingw ports came out compiled with MSVC and died on
# kernel32.lib -- and since upgrade removes a package before it rebuilds it,
# they were left uninstalled rather than merely stale. Repeating the whole bare
# upgrade afterwards with the mingw environment set, which is what used to
# follow it, only rebuilt what the first pass had already broken.
#
# Ask per triplet instead, with that triplet's environment set and every
# package installed for it named. Naming them is what keeps the plan inside the
# triplet: vcpkg widens to the whole tree only when it is given nothing, so
# never hand it an empty list.
foreach ($triplet in $build_triplets) {
    foreach ($tk in $triplet.toolkits) {
        setup_build_env $triplet $tk

        # Feature rows -- "bzip2[tool]:x86-mingw-static" -- carry no version, so
        # the digit in the pattern leaves them out and this stays port names.
        $installed = @(vcpkg-list | ?{ $_ -match (":$triplet" + '\s+\d') } |
                       %{ $_ -replace ':.*','' } | ?{ $_ } | select-object -unique)

        if ($installed) {
            vcpkg --triplet $triplet upgrade --no-binarycaching --no-dry-run --allow-unsupported @installed
        }
    }
}

teardown_build_env

'Finished building and upgrading all dependencies and testing the build for all triplets, please check the log for any issues.'
