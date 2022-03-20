chcp 65001 > $null

set-culture en-US

$env:PATH          += ';' + (resolve-path '/program files/git/cmd') + ';' + (resolve-path '/program files/osslsigncode')
$env:VCPKG_ROOT     = '/source/repos/vcpkg'
$env:VBAM_NO_PAUSE  = 1

$REPO_PATH = '/source/repos/visualboyadvance-m-nightly'
$STAGE_DIR = '/windows/temp/vbam-nightly-build'

$saved_env = [ordered]@{}

function save_env {
    if (-not $saved_env.count) {
	foreach ($var in (gci env:)) {
	    $saved_env[$var.name] = $var.value
	}
    }
}

function restore_env {
    if ($saved_env.count) {
	ri -fo env:*

	$saved_env.getenumerator() | %{
	    set-item -fo "env:$($_.key)" -val $_.value
	}
    }
}

function load_vs_env($arch) {
    $bits = if ($arch -eq 'x86') { 32 } else { 64 }

    restore_env
    save_env

    pushd 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build'

    cmd /c "vcvars${bits}.bat & set" | where { $_ -match '=' } | %{
        $var,$val = $_.split('=')

        set-item -fo "env:$var" -val $val
    }

    popd
}

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

if (-not (test-path $REPO_PATH)) {
    ni -it dir $REPO_PATH | out-null

    pushd (resolve-path "$REPO_PATH/..")

    git clone 'https://github.com/visualboyadvance-m/visualboyadvance-m.git' visualboyadvance-m-nightly

    popd

    $force_build = $true
}

pushd $REPO_PATH

git fetch --all --prune

$head    = $(git rev-parse --short HEAD)
$current = $(git rev-parse --short origin/master)

$sources_changed = $(
    git diff --name-only "${head}..${current}" `
	| grep -cE 'cmake|CMake|\.(c|cpp|h|in|xrc|xml|rc|cmd|xpm|ico|icns|png|svg)$' `
)

$translations_changed = $(
    git diff --name-only "${head}..${current}" `
	| grep -cE 'po/wxvbam/.*\.po$' `
)

# Write date and time for beginning of check/build.
date

if (($sources_changed      -eq 0) -and `
    ($translations_changed -gt 0)) {
	write 'INFO: Building translations.zip only.'
	$translations_only = $true
}

if ((-not $force_build) -and `
    ($sources_changed -eq 0) -and `
    (-not $translations_only)) {
	write 'INFO: No changes to build.'
	popd
	return
}

write "INFO: Build started on $(date)."

git pull --rebase

:arch foreach ($arch in 'x64', 'x86') {
    foreach ($build in 'Release', 'Debug') {
	if (test-path "build-$arch-$build") {
	    ri -r -fo "build-$arch-$build"
	}

	mkdir "build-$arch-$build" | out-null

	load_vs_env $arch

	pushd "build-$arch-$build"

	$error = $null

	$translations_only_str = if ($translations_only) `
	    { 'TRUE' } else { 'FALSE' };

	try {
	    cmake .. -DVCPKG_TARGET_TRIPLET="${arch}-windows-static" -DCMAKE_BUILD_TYPE="$build" -DUPSTREAM_RELEASE=TRUE -DTRANSLATIONS_ONLY="${translations_only_str}" -G Ninja

	    if (-not (test-path build.ninja)) { throw 'cmake failed' }

	    ninja

	    if (-not $?) { throw 'build failed' }
	}
	catch { $error = "$psitem" }

	popd

	restore_env

	# Restore tree state in case any changes were made.
	git reset --hard HEAD

	if ($error) {
	    write-error $error
	    popd
	    return
	}

	if ($translations_only) {
	    break arch
	}
    }
}

ri -r -fo $STAGE_DIR -ea ignore

mkdir $STAGE_DIR | out-null

if (-not $translations_only) {
    cpi -fo build-*/*.zip $STAGE_DIR
}
else {
    cpi -fo build-*/translations.zip  $STAGE_DIR
}

popd

pushd $STAGE_DIR

gci -n | %{ echo "put $_`nchmod 664 $_" | sftp sftpuser@posixsh.org:nightly.vba-m.com/ }

popd

ri -r -fo $STAGE_DIR

write 'INFO: Build successful!'
