import-module -force "$psscriptroot/vbam-builder.psm1"

#$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$stage_dir = join-path $env:TEMP vbam-nightly-build

$force_build = $args | ?{ $_ -match '^--?f' }

$build_triplets = get-triplets @args | ?{
    ($_ -in 'x64-windows-static','x86-mingw-static','arm64-windows-static') -or
    ($_ -in $ANDROID_TRIPLETS)
}

# Which checkout a triplet builds out of. Android gets one of its own: what
# decides whether there is anything to build is the checkout's HEAD against
# origin/master, and a run that builds then advances HEAD to match, so out of a
# shared checkout the first run to finish tells every later one that nothing
# changed -- an Android nightly following a Windows one would find its APKs
# perpetually stale and never rebuild them. Answered per triplet rather than
# once for the run, so a set holding both kinds gets both checkouts.
function repo_for_triplet($triplet) {
    join-path $REPOS_ROOT $(
	if ($triplet -in $ANDROID_TRIPLETS) { 'visualboyadvance-m-nightly-android' }
	else                                { 'visualboyadvance-m-nightly' }
    )
}

# On Windows this is the grep.exe from Git for Windows, spelled with the
# extension so it is not taken for a PowerShell command; elsewhere it is the
# binary's own path, resolved rather than named because a grep function in the
# profile shadows the name. -commandtype application is what skips that
# function, and the path it returns cannot be shadowed again at call time.
# Behind a variable because the Android builds run on Linux and macOS.
$grep = if ($iswindows) { 'grep.exe' } else {
    (get-command -commandtype application grep -ea stop | select -first 1).source
}

# Write date and time for beginning of check/build.
date

# What to build, as one entry per triplet naming the checkout it comes out of
# and whether that checkout has anything but translations to offer. Each
# checkout is fetched and asked once, however many triplets it carries.
$plan = @()

foreach ($repo_path in @($build_triplets | %{ repo_for_triplet $_ } | select -unique)) {
    $repo_name = split-path -leaf $repo_path
    $forced    = [bool]$force_build

    if (-not (test-path $repo_path)) {
	pushd $REPOS_ROOT

	git clone https://github.com/visualboyadvance-m/visualboyadvance-m.git $repo_name

	popd

	$forced = $true
    }

    pushd $repo_path

    git fetch --all --prune
    git submodule update --init --recursive
    git submodule update

    $head    = $(git rev-parse --short HEAD)
    $current = $(git rev-parse --short origin/master)

    $sources_changed = $(
	git diff --name-only "${head}..${current}" `
	    | & $grep -cE 'cmake|CMake|\.(c|cpp|java|h|in|xrc|xml|rc|cmd|xpm|ico|icns|png|svg)$' `
    )

    $translations_changed = $(
	git diff --name-only "${head}..${current}" `
	    | & $grep -cE 'po/wxvbam/.*\.po$' `
    )

    $translations_only = ($sources_changed      -eq 0) -and `
			 ($translations_changed -gt 0)

    if ((-not $forced) -and `
	($sources_changed -eq 0) -and `
	(-not $translations_only)) {
	"INFO: No changes to build in ${repo_name}."
	popd
	continue
    }

    if ($translations_only) {
	"INFO: Building translations.zip only in ${repo_name}."
    }

    git pull --rebase

    popd

    $repo_triplets = @($build_triplets | ?{ (repo_for_triplet $_) -eq $repo_path })

    # translations.zip does not depend on the architecture, so one build of it
    # is all a checkout needs however many triplets asked for it.
    if ($translations_only) {
	$repo_triplets = @($repo_triplets | select -first 1)
    }

    $plan += @($repo_triplets | %{
	@{ triplet = $_; repo = $repo_path; translations_only = $translations_only }
    })
}

if (-not $plan) {
    'INFO: No changes to build.'
    return
}

"INFO: Build started on $(date)."

foreach ($item in $plan) {
    $triplet   = $item.triplet
    $build_dir = "$($item.repo)/build-$triplet"

    ri -r -fo  $build_dir -ea ignore
    ni -it dir $build_dir | out-null

    pushd $build_dir

    if ($triplet -match 'x64-windows') {
	setup_build_env $triplet v143
    }
    else {
	setup_build_env $triplet
    }

    $translations_only_str = if ($item.translations_only) `
	{ 'TRUE' } else { 'FALSE' };

    if ($triplet -in $ANDROID_TRIPLETS) {
	# The NDK toolchain file the vcpkg triplet chainloads selects the
	# compiler, so naming one here would only fight it. ANDROID_HOME and
	# ANDROID_NDK_HOME come from the environment; the project derives
	# ANDROID_ABI and the API level from the triplet.
	& cmake .. -DVCPKG_TARGET_TRIPLET="$triplet" -DCMAKE_BUILD_TYPE=Release -DUPSTREAM_RELEASE=TRUE `
		   -DTRANSLATIONS_ONLY="$translations_only_str" -DBUILD_TESTING=FALSE `
		   -G Ninja
    }
    else {
	$compiler = if ($triplet -match 'mingw') { 'gcc' } else { (get-command cl).source }

	& cmake .. -DVCPKG_TARGET_TRIPLET="$triplet" -DCMAKE_BUILD_TYPE=Release -DUPSTREAM_RELEASE=TRUE `
		   -DTRANSLATIONS_ONLY="$translations_only_str" -DBUILD_TESTING=FALSE `
		   -DCMAKE_C_COMPILER="$compiler" -DCMAKE_CXX_COMPILER="$compiler" `
		   -G Ninja
    }

    if (test-path build.ninja) { ninja }

    popd
}

teardown_build_env

ri -r -fo  $stage_dir -ea ignore
ni -it dir $stage_dir | out-null

foreach ($item in $plan) {
    # The Android builds produce visualboyadvance-m-<ARCH_NAME>.apk, the native
    # ones a zip; either way the name the build chose is the name that gets
    # published.
    $artifacts = if     ($item.translations_only)         { 'translations.zip' }
		 elseif ($item.triplet -in $ANDROID_TRIPLETS) { '*.apk' }
		 else                                         { '*.zip' }

    cpi -fo "$($item.repo)/build-$($item.triplet)/$artifacts" $stage_dir
}

pushd $stage_dir

gci -n | %{ ("put {0}`nchmod 664 {0}" -f $_) | sftp sftpuser@posixsh.org:nightly.visualboyadvance-m.org/ }

popd

ri -r -fo $stage_dir

'INFO: Build successful!'
