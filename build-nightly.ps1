$erroractionpreference = 'stop'

[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'

[Console]::OutputEncoding = [Console]::InputEncoding = `
    $OutputEncoding = new-object System.Text.UTF8Encoding

$env:PATH          += ';' + (resolve-path '/program files/git/cmd')
$env:VCPKG_ROOT     = '/source/repos/vcpkg'
$env:MSYSTEM        = 'MINGW32'

. $profile

$repo_path = '/source/repos/visualboyadvance-m-nightly'
$stage_dir = $env:TEMP + '/vbam-nightly-build'

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
    restore_env
    save_env

    pushd '/program files/microsoft visual studio/2022/community/vc/auxiliary/build'

    $vs_path = '/program files/microsoft visual studio/2022/community/common7/tools'

    $arch = if ($arch -eq 'x64') { 'amd64' } else { $arch }

    $saved_vcpkg_root = $env:VCPKG_ROOT

    & $vs_path/launch-vsdevshell.ps1 -hostarch amd64 -arch $arch -skipautomaticlocation

    if ($saved_vcpkg_root) {
	$env:VCPKG_ROOT = $saved_vcpkg_root
    }

    popd
}

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

if (-not (test-path $repo_path)) {
    ni -it dir $repo_path | out-null

    pushd (resolve-path "$repo_path/..")

    git clone 'https://github.com/visualboyadvance-m/visualboyadvance-m.git' visualboyadvance-m-nightly

    popd

    $force_build = $true
}

pushd $env:VCPKG_ROOT

git pull --rebase
& ./bootstrap-vcpkg.bat

popd

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

#:arch foreach ($arch in 'x64', 'x86', 'arm64') {
:arch foreach ($arch in 'x64', 'x86') {
    :build foreach ($build in 'Release', 'Debug') {
	if (test-path "build-$arch-$build") {
	    ri -r -fo "build-$arch-$build"
	}

	mkdir "build-$arch-$build" | out-null

	if ($arch -eq 'x86') {
	    $triplet = "${arch}-mingw-static"
	    save_env
	    $env:PATH = 'C:/msys64/mingw32/bin;' + $env:PATH
	}
	else {
	    $triplet = "${arch}-windows-static"
	    load_vs_env $arch
	}

	pushd "build-$arch-$build"

	$error = $null

	$translations_only_str = if ($translations_only) `
	    { 'TRUE' } else { 'FALSE' };

	try {
	    cmake .. -DVCPKG_TARGET_TRIPLET="$triplet" -DCMAKE_BUILD_TYPE="$build" -DENABLE_FAUDIO=TRUE -DUPSTREAM_RELEASE=TRUE -DTRANSLATIONS_ONLY="${translations_only_str}" -G Ninja

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

ri -r -fo $stage_dir -ea ignore

mkdir $stage_dir | out-null

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
