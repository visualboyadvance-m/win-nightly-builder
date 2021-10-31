chcp 65001 > $null

set-culture en-US

$env:PATH          += ';' + (resolve-path '/program files/git/cmd') + ';' + (resolve-path '/program files/osslsigncode')
$env:VCPKG_ROOT     = '/source/repos/vcpkg'
$env:VBAM_NO_PAUSE  = 1

$REPO_PATH = '/source/repos/visualboyadvance-m-nightly'
$WEB_DIR   = '/inetpub/wwwroot/nightly'

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
	remove-item -force env:*

	$saved_env.getenumerator() | %{
	    set-item -force "env:$($_.key)" -value $_.value
	}
    }
}

function load_vs_env {
    param([string]$arch)

    $bits = if ($arch -eq 'x86') { 32 } else { 64 }

    restore_env
    save_env

    pushd 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build'

    cmd /c "vcvars${bits}.bat & set" | where { $_ -match '=' } | %{
        $var,$val = $_.split('=')

        set-item -force "env:$var" -value $val
    }

    popd
}

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

if (-not (test-path $REPO_PATH)) {
    new-item -itemtype directory $REPO_PATH | out-null

    pushd (resolve-path "$REPO_PATH/..")

    git clone 'https://github.com/visualboyadvance-m/visualboyadvance-m.git' visualboyadvance-m-nightly

    popd

    $force_build = $true
}

pushd $REPO_PATH

git fetch --all --prune

if ((-not $force_build) -and (git status | select-string '^Your branch is up to date with')) {
    write-output 'INFO: No changes to build.'
    popd
    return
}

write-output "INFO: Build started on $(get-date)"

git pull --rebase

foreach ($arch in 'x64', 'x86') {
    foreach ($build in 'Release', 'Debug') {
	if (test-path "build-$arch-$build") {
	    remove-item -recurse -force "build-$arch-$build"
	}

	new-item -itemtype directory "build-$arch-$build" | out-null

	load_vs_env $arch

	pushd "build-$arch-$build"

	$error = $null

	try {
	    cmake .. -DVCPKG_TARGET_TRIPLET="${arch}-windows-static" -DCMAKE_BUILD_TYPE="$build" -DUPSTREAM_RELEASE=TRUE -G Ninja

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
    }
}

gci build-*/*.zip | %{ cpi -force $_ $WEB_DIR }

if (test-path $WEB_DIR/web.config) {
    ri -recurse -force $WEB_DIR/web.config
}

write-output @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <system.webServer>
        <directoryBrowse enabled="true" showFlags="Date, Time, Size, Extension, LongDate" />
    </system.webServer>
</configuration>
'@ > $WEB_DIR/web.config

(gi -force $WEB_DIR/web.config).attributes += 'hidden'

popd

write-output 'INFO: Build successful!'
