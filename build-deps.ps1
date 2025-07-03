. $profile

$root = if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME }

$erroractionpreference = 'ignore'

$ports = write pkgconf zlib pthreads 'sdl3[vulkan]' gettext-libintl wxwidgets openal-soft nanosvg 'ffmpeg[x264,x265]' faudio

$triplets = (write x64 x86 arm64 | %{ "$_-windows" } | %{ $_,"$_-static" }),'x86-mingw-static','x64-mingw-static' | write

if (-not (test-path $env:VCPKG_ROOT -ea ignore)) {
    pushd (split-path -parent $env:VCPKG_ROOT)

    git clone git@github.com:microsoft/vcpkg

    popd
}

pushd $env:VCPKG_ROOT

git pull --rebase
./bootstrap-vcpkg.bat

popd

$vcpkg = join-path $env:VCPKG_ROOT vcpkg.exe

function setup_build_env([string]$triplet) {
    $triplet -match '^([^-]+)' | out-null
    $arch = $matches[1]

    if ($triplet -match 'mingw') {
	ri variable:global:orig_path -ea ignore

	if ($arch -eq 'x86') {
	    $global:orig_path = $env:PATH
	    $env:PATH         = 'c:/msys64/mingw32/bin;' + $env:PATH
	}
	elseif ($arch -eq 'x64') {
	    $global:orig_path = $env:PATH
	    $env:PATH         = 'c:/msys64/clang64/bin;' + $env:PATH
	}
    }
    else { # MSVC
	if ($arch -eq 'x64') {
	    $arch = 'amd64'
	}

	vsenv $arch
    }
}

function teardown_build_env([string]$triplet) {
    if ($global:orig_path) {
	$env:PATH = $global:orig_path
    }
}

$build_triplets = $args

if (-not $requested_build_triplets) { $requested_build_triplets = $triplets }

$build_triplets = [ordered]@{}

foreach ($triplet in $requested_build_triplets) {
    $triplet = $triplet.tolower()

    if ($triplet -match '^(x[86][64]|arm64)$') {
	$build_triplets["$triplet-windows-static"] = 1
    }
    elseif ($triplet -match '^(x[86]|[64])-mingw$') {
	$build_triplets["$triplet-mingw-static"] = 1
    }
    else {
	$build_triplets[$triplet] = 1
    }
}

foreach ($triplet in $build_triplets.keys) {
    setup_build_env $triplet

    &$vcpkg --triplet $triplet install --recurse --keep-going $ports
    &$vcpkg --triplet $triplet upgrade ($ports -replace '\[[^\]]+\]','') --no-dry-run

    $build_dir = join-path (convert-path ~/source/repos) visualboyadvance-m/build-$triplet

    ni -it dir $build_dir -ea ignore | out-null

    pushd $build_dir

    ri -r -fo *

    cmake .. "-DVCPKG_TARGET_TRIPLET=$triplet" -DCMAKE_BUILD_TYPE=Release -G Ninja
    ninja

    popd

    teardown_build_env $triplet
}
