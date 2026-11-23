import-module -force $psscriptroot/vbam-builder.psm1

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$build_triplets = resolve-triplets @args

$repo_path = join-path (get-reposroot) visualboyadvance-m

if (-not (test-path $repo_path)) {
    pushd (get-reposroot)

    git clone git@github.com:visualboyadvance-m/visualboyadvance-m

    popd
}

pushd $repo_path

git pull --rebase
git submodule update --init --recursive

popd

foreach ($triplet in $build_triplets) {
    foreach ($tk in $triplet.toolkits) {
        enter-buildenv $triplet $tk

        $build_dir = join-path $repo_path build-$triplet

        ni -it dir $build_dir   -ea ignore | out-null
        ri -r -fo  $build_dir/* -ea ignore

        pushd $build_dir

        cmake .. -DCMAKE_BUILD_TYPE=Release -DVCPKG_TARGET_TRIPLET="$triplet" -DVCPKG_SOURCE_PACKAGES=FALSE -DUPSTREAM_RELEASE=TRUE -G Ninja

        popd
    }
}

exit-buildenv

'Finished downloading all dependencies, please check the log for any issues.'
