import-module -force $psscriptroot/vbam-builder.psm1

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$build_triplets = $args | get-triplets

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

    $build_dir = join-path $repo_path build-$triplet

    ni -it dir $build_dir   -ea ignore | out-null
    ri -r -fo  $build_dir/* -ea ignore

    pushd $build_dir

    cmake .. -DCMAKE_BUILD_TYPE=Release -DVCPKG_TARGET_TRIPLET="$triplet" -DUPSTREAM_RELEASE=TRUE -G Ninja

    popd
}

teardown_build_env

'Finished downloading all dependencies, please check the log for any issues.'
