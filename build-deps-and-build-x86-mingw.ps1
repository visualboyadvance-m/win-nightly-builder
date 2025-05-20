. $profile

$erroractionpreference = 'stop'

$ports = write pkgconf zlib pthreads sdl3 gettext wxwidgets openal-soft nanosvg sfml ffmpeg

$triplet = 'x86-mingw-static'

$env:PATH = 'c:/msys64/mingw32/bin;' + $env:PATH

vcpkg --triplet $triplet install $ports
vcpkg --triplet $triplet upgrade ($ports -replace '\[[^\]]+\]','') --no-dry-run

$build_dir = join-path (convert-path ~/source/repos) visualboyadvance-m/build-$triplet

ni -it dir $build_dir -ea ignore | out-null

pushd $build_dir

ri -r -fo *

cmake .. "-DVCPKG_TARGET_TRIPLET=$triplet" -DCMAKE_BUILD_TYPE=Release -G Ninja
ninja

popd
