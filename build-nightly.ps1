import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$repo_path = join-path $REPOS_ROOT visualboyadvance-m-nightly
$stage_dir = join-path $env:TEMP   vbam-nightly-build

$force_build = if ($args[0] -match '^--?f') { $true } else { $false }

update_vcpkg

if (-not (test-path $repo_path -ea ignore)) {
    pushd $REPOS_ROOT

    git clone https://github.com/visualboyadvance-m/visualboyadvance-m.git visualboyadvance-m-nightly

    popd

    $force_build = $true
}

pushd $repo_path

git fetch --all --prune

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

:triplet foreach ($triplet in $TRIPLETS) {
    :build foreach ($build_type in 'Release', 'Debug') {
	$build_dir = "build-$triplet-$build_type"

	ri -r -fo  $build_dir -ea ignore
	ni -it dir $build_dir | out-null

	pushd $build_dir

	setup_build_env $triplet

	$error = $null

	$translations_only_str = if ($translations_only) `
	    { 'TRUE' } else { 'FALSE' };

	try {
	    cmake .. -DVCPKG_TARGET_TRIPLET=$triplet -DCMAKE_BUILD_TYPE=$build_type -DUPSTREAM_RELEASE=TRUE -DTRANSLATIONS_ONLY=$translations_only_str -G Ninja

	    if (-not (test-path build.ninja -ea ignore)) { throw 'cmake failed' }

	    ninja

	    if (-not $?) { throw 'build failed' }
	}
	catch { $error = "$psitem" }

	popd

	teardown_build_env $triplet

	if ($error) {
	    write-error $error
	    popd
	    return
	}

	if ($translations_only) {
	    break triplet
	}
    }
}

ri -r -fo  $stage_dir -ea ignore
ni -it dir $stage_dir | out-null

if (-not $translations_only) {
    cpi -fo build-*/*.zip $stage_dir
}
else {
    cpi -fo build-*/translations.zip  $stage_dir
}

popd

pushd $stage_dir

gci -n | %{ ("put {0}`nchmod 664 {0}" -f $_) | sftp sftpuser@posixsh.org:nightly.visualboyadvance-m.org/ }

popd

ri -r -fo $stage_dir

'INFO: Build successful!'
