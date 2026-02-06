[system.globalization.cultureinfo]::currentculture = 'en-US'

[console]::outputencoding = [console]::inputencoding = `
    $outputencoding = new-object system.text.utf8encoding

$REPOS_ROOT     = $(if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME }) + '/source/repos'

$DEP_PORTS      = echo zlib bzip2 'liblzma[tools]' pthreads 'sdl3[vulkan]' faudio gettext-libintl nanosvg 'wxwidgets[core]' openal-soft 'ffmpeg[x264,x265]'

if ($islinux) {
    $DEP_PORTS  = @('gtk3[wayland]') + $DEP_PORTS
}

$DEP_PORT_NAMES = $DEP_PORTS -replace '\[[^\]]+\]',''

$TRIPLETS       = if ($iswindows) {
		      'x86-mingw-static','x64-mingw-static',(echo x64 x86 arm64 | %{ "$_-windows" } | %{ $_,"$_-static" }) | echo
		  } elseif ($islinux) {
		      'x64-linux'
		  } elseif ($ismacos) {
		      'x64-osx','arm64-osx'
		  }

if ((test-path '/program files/git/cmd') -and ($env:PATH -notmatch '[/\\]git[/\\]cmd')) {
    $env:PATH += ';' + (resolve-path '/program files/git/cmd')
}

if (-not $env:VCPKG_ROOT) {
    $env:VCPKG_ROOT = join-path $REPOS_ROOT vcpkg
}

set-alias -force vcpkg (join-path $env:VCPKG_ROOT $(if ($iswindows) { 'vcpkg.exe' } else { 'vcpkg' }))

if ($islinux) {
    ri -force env:VCPKG_OVERLAY_PORTS -ea ignore
}
elseif (-not $env:VCPKG_OVERLAY_PORTS) {
    $env:VCPKG_OVERLAY_PORTS = join-path $REPOS_ROOT vcpkg-overlay
}

if (($islinux -or $ismacos) -and (-not $env:TEMP)) { $env:TEMP = '/tmp' }

$script:saved_env = [ordered]@{}

function save_env {
    $script:saved_env.clear()

    gci env: | %{ $script:saved_env[$_.name] = $_.value }
}

function restore_env {
    if (-not $script:saved_env.count) { return }

    ri -force env:*

    $script:saved_env.getenumerator() | %{
	si -path env:$($_.key) -value $_.value
    }
}

$script:current_vsenv = $null

if ($iswindows) {
    # Load VS env only once.
    :OUTER foreach ($vs_year in '18','2022','2019','2017') {
        foreach ($vs_type in 'preview','buildtools','community') {
            foreach ($x86 in '',' (x86)') {
                $vs_path="/program files${x86}/microsoft visual studio/${vs_year}/${vs_type}/common7/tools"

                if (test-path $vs_path) {
                    break OUTER
                }
                else {
                    $vs_path=$null
                }
            }
        }
    }

    if ($vs_path) {
        $default_arch = $env:PROCESSOR_ARCHITECTURE.tolower()

        function vsenv([string]$arch) {
            if (-not $arch)      { $arch = $default_arch }
            if ($arch -eq 'x64') { $arch = 'amd64' }

	    if ($script:current_vsenv -eq $arch) { return }

            $saved_vcpkg_root = $env:VCPKG_ROOT

            & $vs_path/Launch-VsDevShell.ps1 -arch $arch -skipautomaticlocation

            if ($saved_vcpkg_root) {
                $env:VCPKG_ROOT = $saved_vcpkg_root
            }

	    $script:current_vsenv = $arch
        }
    }
}

function update_vcpkg {
    if (-not (test-path $env:VCPKG_ROOT)) {
	pushd $REPOS_ROOT

	git clone git@github.com:microsoft/vcpkg

	popd
    }

    pushd $env:VCPKG_ROOT

    git pull --rebase

    if ($iswindows) { ./bootstrap-vcpkg.bat }
    else            { ./bootstrap-vcpkg.sh }

    popd

    if (-not $islinux) {
        if (-not (test-path $env:VCPKG_OVERLAY_PORTS)) {
            pushd $REPOS_ROOT

            git clone git@github.com:visualboyadvance-m/vcpkg-overlay

            popd
        }

        pushd $env:VCPKG_OVERLAY_PORTS

        git pull --rebase

        popd
    }

    if (-not (test-path $REPOS_ROOT/vcpkg-binpkg-prototype)) {
        pushd $REPOS_ROOT

        git clone git@github.com:rkitover/vcpkg-binpkg-prototype

        popd
    }

    pushd $REPOS_ROOT/vcpkg-binpkg-prototype

    git pull --rebase

    popd

    import-module -global -force "$REPOS_ROOT/vcpkg-binpkg-prototype/vcpkg-binpkg.psm1"
}

$script:current_arch      = $null
$script:current_toolchain = $null

function setup_build_env([string]$triplet) {
    if (-not $iswindows) { return }

    $triplet -match '^([^-]+)-([^-]+)' | out-null
    $arch      = $matches[1]
    $toolchain = $matches[2]

    if (($arch -eq $script:current_arch) -and ($toolchain -eq $script:current_toolchain)) { return }

    $script:current_arch      = $arch
    $script:current_toolchain = $toolchain

    restore_env
    save_env

    if ($triplet -match 'mingw') {
	if ($arch -eq 'x86') {
	    $env:PATH = 'c:/msys64/mingw32/bin;' + $env:PATH
	}
	elseif ($arch -eq 'x64') {
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

function teardown_build_env {
    restore_env
    $script:current_vsenv     = $null
    $script:current_arch      = $null
    $script:current_toolchain = $null
}

function get-triplets {
    if ($myinvocation.expectinginput) { $args = $input }

    $requested_triplets = $args | %{ $_.tolower() } | %{
        if ($_ -match '^(x[86][64]|arm64)$') {
            "$_-windows-static"
        }
        elseif ($_ -match '^(x[86]|[64])-mingw$') {
            "$_-mingw-static"
        }
        elseif ($_ -notmatch '^-') {
            $_
        }
    } | select -unique

    if (-not $requested_triplets) { return $TRIPLETS }

    $requested_triplets
}

export-modulemember -variable REPOS_ROOT,DEP_PORTS,DEP_PORT_NAMES `
		    -function update_vcpkg,setup_build_env,teardown_build_env,get-triplets `
		    -alias vcpkg
