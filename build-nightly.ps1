import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$default_triplets = write x86-mingw-static x64-windows-static arm64-windows-static

$CMAKE = if ($iswindows) { '/progra~1/cmake/bin/cmake.exe' } else { 'cmake' }

$repo_path = join-path $REPOS_ROOT visualboyadvance-m-nightly
$stage_dir = join-path $env:TEMP   vbam-nightly-build

$force_build = $args | ?{ $_ -match '^--?f' }

if (-not ($build_triplets = $args | get-triplets)) {
    $build_triplets = $default_triplets
}

update_vcpkg

if (-not (test-path $repo_path)) {
    pushd $REPOS_ROOT

    git clone https://github.com/visualboyadvance-m/visualboyadvance-m.git visualboyadvance-m-nightly

    popd

    $force_build = $true
}

pushd $repo_path

git fetch --all --prune
git submodule update --init --recursive

$head    = $(git rev-parse --short HEAD)
$current = $(git rev-parse --short origin/master)

$sources_changed = $(
    git diff --name-only "${head}..${current}" `
	| grep.exe -cE 'cmake|CMake|\.(c|cpp|h|in|xrc|xml|rc|cmd|xpm|ico|icns|png|svg)$' `
)

$translations_changed = $(
    git diff --name-only "${head}..${current}" `
	| grep.exe -cE 'po/wxvbam/.*\.po$' `
)

# Write date and time for beginning of check/build.
date

if (($sources_changed      -eq 0) -and `
    ($translations_changed -gt 0)) {
	'INFO: Building translations.zip only.'
	$translations_only = $true
}

if ((-not $force_build) -and `
    ($sources_changed -eq 0) -and `
    (-not $translations_only)) {
	'INFO: No changes to build.'
	popd
	return
}

"INFO: Build started on $(date)."

git pull --rebase

popd

:triplet foreach ($triplet in $build_triplets) {
    :build foreach ($build_type in 'Release', 'Debug') {
	$build_dir = "$repo_path/build-$triplet-$build_type"

	ri -r -fo  $build_dir -ea ignore
	ni -it dir $build_dir | out-null

	pushd $build_dir

	setup_build_env $triplet

	$error = $null

	$compiler = if ($triplet -match 'mingw') { 'gcc' } else { (get-command cl).source }

	$translations_only_str = if ($translations_only) `
	    { 'TRUE' } else { 'FALSE' };

	try {
	    & $CMAKE .. -DVCPKG_TARGET_TRIPLET="$triplet" -DCMAKE_BUILD_TYPE="$build_type" -DUPSTREAM_RELEASE=TRUE `
			-DTRANSLATIONS_ONLY="$translations_only_str" `
			-DCMAKE_C_COMPILER="$compiler" -DCMAKE_CXX_COMPILER="$compiler" `
			-G Ninja

	    if (-not (test-path build.ninja)) { throw 'cmake failed' }

	    ninja

	    if (-not $?) { throw 'build failed' }
	}
	catch { $error = "$psitem" }

	popd

	if ($error) {
	    teardown_build_env
	    write-error $error
	    return
	}

	if ($translations_only) {
	    break triplet
	}
    }
}

teardown_build_env

ri -r -fo  $stage_dir -ea ignore
ni -it dir $stage_dir | out-null

if (-not $translations_only) {
    foreach ($triplet in $build_triplets) {
	cpi -fo $repo_path/build-$triplet-*/*.zip $stage_dir
    }
}
else {
    cpi -fo $repo_path/build-*/translations.zip  $stage_dir
}

popd

pushd $stage_dir

gci -n | %{ ("put {0}`nchmod 664 {0}" -f $_) | sftp sftpuser@posixsh.org:nightly.visualboyadvance-m.org/ }

popd

ri -r -fo $stage_dir

'INFO: Build successful!'
