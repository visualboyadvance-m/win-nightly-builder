. $profile

$erroractionpreference = 'stop'

$ports = write pkgconf zlib pthreads 'sdl3[vulkan]' 'gettext[tools]' wxwidgets openal-soft nanosvg 'ffmpeg[x264,x265]' faudio

$triplet = 'x64-mingw-static'

$orig_path = $env:PATH
$env:PATH  = 'c:/msys64/clang64/bin;' + $env:PATH

vcpkg --triplet $triplet install --recurse $ports
vcpkg --triplet $triplet upgrade ($ports -replace '\[[^\]]+\]','') --no-dry-run

$build_dir = join-path (convert-path ~/source/repos) visualboyadvance-m/build-$triplet

ni -it dir $build_dir -ea ignore | out-null

pushd $build_dir

ri -r -fo *

cmake .. "-DVCPKG_TARGET_TRIPLET=$triplet" -DCMAKE_BUILD_TYPE=Release -G Ninja
ninja

popd

$env:PATH = $orig_path
