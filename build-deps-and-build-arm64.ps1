. $profile

$erroractionpreference = 'stop'

$ports = write pkgconf zlib pthreads 'sdl3[vulkan]' 'gettext[tools]' wxwidgets openal-soft nanosvg 'ffmpeg[x264,x265]' faudio

$base_triplet = 'arm64-windows'

vsenv arm64

foreach($suffix in @('','-static')) {
    $triplet = "${base_triplet}${suffix}"

    vcpkg --triplet $triplet install --recurse $ports
    vcpkg --triplet $triplet upgrade ($ports -replace '\[[^\]]+\]','') --no-dry-run

    $saved_overlay = $env:VCPKG_OVERLAY_PORTS

    ri env:VCPKG_OVERLAY_PORTS -ea ignore

    vcpkg --triplet $triplet install --recurse wxwidgets
    vcpkg --triplet $triplet upgrade wxwidgets --no-dry-run

    $env:VCPKG_OVERLAY_PORTS = $saved_overlay

    $build_dir = join-path (convert-path ~/source/repos) visualboyadvance-m/build-$triplet

    ni -it dir $build_dir -ea ignore | out-null

    pushd $build_dir

    ri -r -fo *

    cmake .. "-DVCPKG_TARGET_TRIPLET=$triplet" -DCMAKE_BUILD_TYPE=Release -G Ninja
    ninja

    popd
}
