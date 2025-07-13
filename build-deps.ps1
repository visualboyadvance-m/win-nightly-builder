import-module -force $psscriptroot/vbam-builder.psm1

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$build_triplets = $args

if (-not $build_triplets) { $build_triplets = $TRIPLETS }

$build_triplets = $build_triplets | %{ $_.tolower() } | %{
    if ($_ -match '^(x[86][64]|arm64)$') {
	"$_-windows-static"
    }
    elseif ($_ -match '^(x[86]|[64])-mingw$') {
	"$_-mingw-static"
    }
    else {
	$_
    }
} | select -unique

update_vcpkg

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
    setup_build_env $triplet

    vcpkg --triplet $triplet install --recurse --keep-going $DEP_PORTS
    vcpkg --triplet $triplet upgrade $DEP_PORT_NAMES --no-dry-run

    $build_dir = join-path $repo_path build-$triplet

    ni -it dir $build_dir   -ea ignore | out-null
    ri -r -fo  $build_dir/* -ea ignore

    pushd $build_dir

    cmake .. -DCMAKE_BUILD_TYPE=Release -DVCPKG_TARGET_TRIPLET="$triplet" -DUPSTREAM_RELEASE=TRUE -G Ninja
    ninja

    popd
}

teardown_build_env

# Do full upgrade of all deps, repeat for the MinGW triplets because the toolchain has to be in $env:PATH.
vcpkg upgrade --no-dry-run

foreach ($triplet in (write x86-mingw-static x64-mingw-static)) {
    setup_build_env $triplet
    vcpkg upgrade --no-dry-run
}

teardown_build_env

'Finished building and upgrading all dependencies and testing the build for all triplets, please check the log for any issues.'
