[system.globalization.cultureinfo]::currentculture = 'en-US'

[console]::outputencoding = [console]::inputencoding = `
    $outputencoding = new-object system.text.utf8encoding

$REPOS_ROOT     = $(if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME }) + '/source/repos'
$DEP_PORTS      = write pkgconf zlib pthreads 'sdl3[vulkan]' faudio gettext-libintl nanosvg wxwidgets openal-soft 'ffmpeg[x264,x265]'
$DEP_PORT_NAMES = $DEP_PORTS -replace '\[[^\]]+\]',''
$TRIPLETS       = if ($iswindows) {
		      (write x64 x86 arm64 | %{ "$_-windows" } | %{ $_,"$_-static" }),'x86-mingw-static','x64-mingw-static' | write
		  } elseif ($islinux) {
		      'x64-linux'
		  } elseif ($ismacos) {
		      'x64-macos','arm64-macos'
		  }

if ((test-path '/program files/git/cmd' -ea ignore) -and ($env:PATH -notmatch '[/\\]git[/\\]cmd')) {
    $env:PATH += ';' + (resolve-path '/program files/git/cmd')
}

if (-not $env:VCPKG_ROOT) {
    $env:VCPKG_ROOT = join-path $REPOS_ROOT vcpkg
}

set-alias -force vcpkg (join-path $env:VCPKG_ROOT $(if ($iswindows) { 'vcpkg.exe' } else { 'vcpkg' }))

if (-not $env:VCPKG_OVERLAY_PORTS) {
    $env:VCPKG_OVERLAY_PORTS = join-path $REPOS_ROOT vcpkg-overlay
}

if ($islinux -and (-not $env:TEMP)) { $env:TEMP = '/tmp' }

if ($iswindows) {
    # Load VS env only once.
    :OUTER foreach ($vs_year in '2022','2019','2017') {
        foreach ($vs_type in 'preview','buildtools','community') {
            foreach ($x86 in '',' (x86)') {
                $vs_path="/program files${x86}/microsoft visual studio/${vs_year}/${vs_type}/Common7/Tools"

                if (test-path $vs_path -ea ignore) {
                    break OUTER
                }
                else {
                    $vs_path=$null
                }
            }
        }
    }

    if ($vs_path) {
        $default_host_arch,$default_arch = if ($env:PROCESSOR_ARCHITECTURE -ieq 'AMD64') {
            @('amd64') * 2
        }
        else { @($env:PROCESSOR_ARCHITECTURE.tolower()) * 2 }

        function vsenv([string]$arch, [string]$hostarch) {
            if (-not $arch)     { $arch     = $default_arch }
            if (-not $hostarch) { $hostarch = $default_host_arch }

            if ($arch     -eq 'x64') { $arch     = 'amd64' }
            if ($hostarch -eq 'x64') { $hostarch = 'amd64' }

            $saved_vcpkg_root = $env:VCPKG_ROOT

            & $vs_path/Launch-VsDevShell.ps1 -hostarch $hostarch -arch $arch -skipautomaticlocation

            if ($saved_vcpkg_root) {
                $env:VCPKG_ROOT = $saved_vcpkg_root
            }
        }
    }
}

function update_vcpkg {
    if (-not (test-path $env:VCPKG_ROOT -ea ignore)) {
	pushd $REPOS_ROOT

	git clone git@github.com:microsoft/vcpkg

	popd
    }

    pushd $env:VCPKG_ROOT

    git pull --rebase

    if ($iswindows) { ./bootstrap-vcpkg.bat }
    else            { ./bootstrap-vcpkg.sh }

    popd

    if (-not (test-path $env:VCPKG_OVERLAY_PORTS -ea ignore)) {
	pushd $REPOS_ROOT

	git clone git@github.com:visualboyadvance-m/vcpkg-overlay

	popd
    }

    pushd $env:VCPKG_OVERLAY_PORTS

    git pull --rebase

    popd
}

function setup_build_env([string]$triplet) {
    if (-not $iswindows) { return }

    $triplet -match '^([^-]+)' | out-null
    $arch = $matches[1]

    if ($triplet -match 'mingw') {
	ri variable:global:orig_path -ea ignore

	if ($arch -eq 'x86') {
	    $global:orig_path = $env:PATH
	    $env:PATH = 'c:/msys64/mingw32/bin;' + $env:PATH
	}
	elseif ($arch -eq 'x64') {
	    $global:orig_path = $env:PATH
	    $env:PATH = 'c:/msys64/clang64/bin;' + $env:PATH
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
	ri variable:global:orig_path -ea ignore
    }

    if ($triplet -match '-windows-?') {
	vsenv
    }
}

export-modulemember -variable REPOS_ROOT,DEP_PORTS,DEP_PORT_NAMES,TRIPLETS `
		    -function update_vcpkg,setup_build_env,teardown_build_env `
		    -alias vcpkg
