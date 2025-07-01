. $profile

$erroractionpreference = 'ignore'

$ports = write pkgconf zlib pthreads 'sdl3[vulkan]' gettext-libintl wxwidgets openal-soft nanosvg 'ffmpeg[x264,x265]' faudio

$base_triplet = 'arm64-windows'

vsenv arm64

foreach($suffix in @('','-static')) {
    $triplet = "${base_triplet}${suffix}"

    vcpkg --triplet $triplet install --recurse --keep-going $ports
    vcpkg --triplet $triplet upgrade ($ports -replace '\[[^\]]+\]','') --no-dry-run

    $build_dir = join-path (convert-path ~/source/repos) visualboyadvance-m/build-$triplet

    ni -it dir $build_dir -ea ignore | out-null

    pushd $build_dir

    ri -r -fo *

    cmake .. "-DVCPKG_TARGET_TRIPLET=$triplet" -DCMAKE_BUILD_TYPE=Release -G Ninja
    ninja

    popd
}
