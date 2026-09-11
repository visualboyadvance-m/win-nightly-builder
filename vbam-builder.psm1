[system.globalization.cultureinfo]::currentculture = 'en-US'

[console]::outputencoding = [console]::inputencoding = `
    $outputencoding = new-object system.text.utf8encoding

# Windows PowerShell does not have OS automatic variables.
if (-not (test-path variable:global:iswindows)) {
    $global:IsWindows = $false
    $global:IsLinux   = $false
    $global:IsMacOS   = $false

    if (get-command get-cimsession -ea ignore) {
        $global:IsWindows = $true
    }
    elseif (test-path /System/Library/Extensions) {
        $global:IsMacOS   = $true
    }
    else {
        $global:IsLinux   = $true
    }
}

$ROOT           = $(if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME })

$REPOS_ROOT     = $ROOT + '/source/repos'

# The ports the binary packages are built from, and the features they are built
# with. The features have to be the ones VCPKG_DEPS in the emulator's top-level
# CMakeLists.txt asks for: nothing in a package's name records which features
# went into it, so a consumer that asks for one this list did not build gets a
# package silently short of it, and one that asks for a port whose defaults
# this list turned off ([core]) rebuilds it from source to add them. Ports
# named here and not there are the other way round -- extra features on things
# wxWidgets only pulls in transitively -- and cost the consumer nothing.
#
# x264 and x265 are named for the reason tiff is below: they only ever arrive
# under ffmpeg[x264,x265], and vcpkg upgrade rebuilds the packages it is given
# and their dependents, never their already-installed dependencies. Unnamed,
# they were pinned at whatever version first got installed -- x265 sat at 4.1
# while the overlay was at 4.3 -- and each overlay bump rebuilt ffmpeg against
# the stale copy instead, since a dependency's ABI feeds into ffmpeg's own.
# Their default features are what ffmpeg asks for (x264's asm and gpl, x265 has
# none), so naming them bare changes nothing about how they are built.
$DEP_PORTS      = echo zlib bzip2 'liblzma[tools]' lua pthreads 'sdl3[vulkan,libusb]' faudio gettext-libintl nanosvg 'wxwidgets[core]' openal-soft x264 x265 'ffmpeg[x264,x265]'

# The set before any host's desktop additions. $ANDROID_DEP_PORTS is built from
# this rather than from $DEP_PORTS, which by then carries GTK, X11 and friends.
$COMMON_DEP_PORTS = $DEP_PORTS

if ($islinux) {
    # tiff only arrives transitively here, via wxwidgets and gdk-pixbuf. Build
    # it explicitly so it is upgraded by name along with the rest, and so the
    # vcpkg copy is in place before anything that links it.
    $DEP_PORTS  = @('gtk3[wayland]', 'tiff') + $DEP_PORTS
}

if ($iswindows) {
    $DEP_PORTS  = @('vulkan') + $DEP_PORTS
} elseif ($islinux) {
    $DEP_PORTS  = @('vulkan') + @('vulkan-loader[wayland,xlib,xcb]') + $DEP_PORTS
} elseif ($ismacos) {
    $DEP_PORTS  = @('vulkan-headers') + @('moltenvk') + $DEP_PORTS
}

$DEP_PORT_NAMES = $DEP_PORTS -replace '\[[^\]]+\]',''

# Android is a cross target, not a host, and the desktop pieces the host list
# adds above are not merely useless in an APK but unbuildable: both gtk3 and
# vulkan-loader declare `supports: !android`, and asking for them anyway --
# which --allow-unsupported does -- drags the whole X11 stack behind them for a
# triplet that has no X server. The vulkan port is fine: it gates the loader on
# !android by itself, leaving the headers, which is all the NDK needs.
#
# The other direction is Qt. wxQt is the wx backend on Android, so the target
# needs a Qt that no desktop build asks for; naming it here is also what gets
# the *host* Qt built, since vcpkg records qtbase:<host> as a host dependency
# of qtbase:*-android and both moc and androiddeployqt run on the build
# machine. tiff is named for the reason it is on Linux: wx links it, and naming
# it keeps it upgraded by name instead of only ever arriving transitively.
# SDL3 drops its libusb feature here: on Android the HID backend is the Java one
# under org/libsdl/app, which the APK carries itself, and the feature only turns
# on SDL_HIDAPI_LIBUSB. The port is not platform-gated, so asking for it builds
# libusb for a target that never links it.
$ANDROID_DEP_PORTS = @('vulkan', 'qtbase', 'qttools', 'tiff') +
                     ($COMMON_DEP_PORTS -replace '^sdl3\[.*\]$', 'sdl3[vulkan]')

$ANDROID_DEP_PORT_NAMES = $ANDROID_DEP_PORTS -replace '\[[^\]]+\]',''

# Every port name either list can name, for validating --packages/--skip-packages.
$ALL_DEP_PORT_NAMES = @($DEP_PORT_NAMES) + @($ANDROID_DEP_PORT_NAMES) | select-object -unique

$TRIPLETS       = if ($iswindows) {
		      'x86-mingw-static','x64-mingw-static',(echo x64 x86 arm64 | %{ "$_-windows" } | %{ $_,"$_-static" }) | echo
		  } elseif ($islinux) {
		      # Native only: vcpkg's linux triplets name a target architecture
		      # but no toolchain, so building the other one would need a cross
		      # compiler and a full sysroot. Build whichever the host already is.
		      if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
			  'arm64-linux'
		      } else {
			  'x64-linux'
		      }
		  } elseif ($ismacos) {
		      'x64-osx','arm64-osx'
		  }

# One per APK published on https://nightly.visualboyadvance-m.org/ --
# visualboyadvance-m-{arm64,arm,x86_64,x86,riscv64}.apk.  These are cross
# builds, only set up on Linux and macOS, and they roughly double the work, so
# they are opt-in via --android rather than part of $TRIPLETS.
$ANDROID_TRIPLETS = 'arm64-android','arm-neon-android','x64-android','x86-android','riscv64-android'

# The triplets that can host a build on this platform: the plain OS ones, with
# neither -static nor mingw, which are the triplets vcpkg builds host tools
# for. On Windows that is every architecture's own machine -- x64-windows,
# x86-windows, arm64-windows -- and not only the one this builder happens to
# run on, since an Android build can be hosted on any of them.
$HOST_TRIPLETS = @($TRIPLETS | ?{ $_ -match '^[^-]+-(windows|linux|osx)$' })

if ($iswindows) {
    $git_bin_dir   = '/progra~1/git/cmd'
    $cmake_bin_dir = '/progra~1/cmake/bin'

    if ((test-path $git_bin_dir)   -and ($env:Path -notmatch '[/\\]git[/\\]cmd')) {
        $env:Path += ';' + (resolve-path $git_bin_dir).path
    }

    if ((test-path $cmake_bin_dir) -and ($env:Path -notmatch '[/\\]cmake[/\\]bin')) {
        $env:Path = (resolve-path $cmake_bin_dir).path + ';' + $env:Path
    }
}

if (-not $env:VCPKG_ROOT) {
    $env:VCPKG_ROOT = join-path $REPOS_ROOT vcpkg
}

set-alias -force vcpkg (join-path $env:VCPKG_ROOT $(if ($iswindows) { 'vcpkg.exe' } else { 'vcpkg' }))

# The overlay repo, used on every platform.
$OVERLAY_PORTS  = join-path $REPOS_ROOT vcpkg-overlay

if (-not $env:VCPKG_OVERLAY_PORTS) {
    $env:VCPKG_OVERLAY_PORTS = $OVERLAY_PORTS
}

# The overlay's triplets directory holds riscv64-android, which vcpkg itself has
# no triplet for.  On Windows setup_build_env points VCPKG_OVERLAY_TRIPLETS at a
# per-toolkit directory instead, so leave it alone there.
if ((-not $iswindows) -and (-not $env:VCPKG_OVERLAY_TRIPLETS)) {
    $env:VCPKG_OVERLAY_TRIPLETS = join-path $OVERLAY_PORTS 'triplets/community'
}

if (($islinux -or $ismacos) -and (-not $env:TEMP)) { $env:TEMP = '/tmp' }

$path_sep = [system.io.path]::pathseparator

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

$script:vsenv_state = $null
$script:vsenv_vcpkg_in_path = $null

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
        $vcvarsall = resolve-path "$vs_path/../../VC/Auxiliary/Build/vcvarsall.bat"

        function vsenv {
            param($arch, $toolkit, [switch]$unload)

            # These are semicolon-separated list vars that vcvarsall prepends to.
            $list_vars = 'PATH','INCLUDE','LIB','LIBPATH','EXTERNAL_INCLUDE'

            # Capture current list var values BEFORE unloading.  For
            # LIB/INCLUDE/LIBPATH this preserves user additions (e.g. vcpkg)
            # that were appended after the previous vsenv call.
            $pre_unload = @{}
            foreach ($lv in $list_vars) {
                $pre_unload[$lv] = (get-item -literalpath "env:$lv" -ea ignore).value
            }

            # Grab the record of what vcvarsall added last session before we clear state.
            $prev_additions = if ($script:vsenv_state) { $script:vsenv_state.vcvarsall_additions } else { $null }

            # Regex matching VS/SDK/WinKits/.NET/.NET-adjacent PATH entries added by
            # vcvarsall, used to strip the inherited PATH when starting a new shell
            # that already has a vsenv'd PATH from its parent process, and to strip
            # any that are left in PATH when unloading.
            $vs_strip_re = '[/\\]Microsoft Visual Studio[/\\]|[/\\]Microsoft SDKs[/\\]|[/\\]Windows Kits[/\\](?:[^/\\]+[/\\](?:bin|lib|include|UnionMetadata|References)[/\\]|NETFXSDK[/\\])|[/\\]Microsoft\.NET[/\\]|[/\\]HTML Help Workshop'

            # Unload previous vsenv state.
            if ($script:vsenv_state) {
                # Restore PATH and list vars (INCLUDE, LIB, LIBPATH).
                $script:vsenv_state.saved_lists.getenumerator() | %{
                    # For PATH subtract what vcvarsall added instead of
                    # restoring the saved baseline, which would also discard
                    # entries added to PATH since. Also strip any VS entries
                    # that are not in the record, e.g. ones inherited from a
                    # parent shell.
                    if ($_.key -ieq 'PATH' -and $prev_additions -and
                        $prev_additions['PATH']) {

                        $added = $prev_additions['PATH']

                        $env:Path = (($env:Path -split $path_sep |
                            %{ $_.trim() } | ?{
                                $_ -and $_ -inotmatch $vs_strip_re -and
                                    -not $added[$_.trimend('/\')]
                            }) -join $path_sep)
                    }
                    elseif ($null -ne $_.value) {
                        set-item -literalpath "env:$($_.key)" $_.value
                    } else {
                        remove-item -literalpath "env:$($_.key)" -ea ignore
                    }
                }

                # Restore previous env var values.
                $script:vsenv_state.vars.getenumerator() | %{
                    if ($null -ne $_.value) {
                        set-item -literalpath "env:$($_.key)" $_.value
                    } else {
                        remove-item -literalpath "env:$($_.key)" -ea ignore
                    }
                }

                $script:vsenv_state = $null
            }

            if ($unload) { return }

            # Strip stale VCPKG_ROOT from PATH if it changed since last vsenv
            # call — must happen before $post_unload_path AND before vcvarsall
            # (which inherits $env:Path) so neither sees the old entry.
            $vcpkg_root_trimmed = if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT.trimend('/\') } else { $null }
            if ($script:vsenv_vcpkg_in_path -and $vcpkg_root_trimmed -and
                $script:vsenv_vcpkg_in_path -ine $vcpkg_root_trimmed) {
                $env:Path = ($env:Path -split $path_sep | ?{
                    $_.trim().trimend('/\') -ine $script:vsenv_vcpkg_in_path
                }) -join $path_sep
            }

            # PATH baseline: strip VS-adjacent entries, normalize and dedup.
            $post_unload_dedup = @{}
            $post_unload_path = ($env:Path -split $path_sep | %{ $_.trim().trimend('/\') } | ?{
                $_ -and $_ -inotmatch $vs_strip_re -and -not $post_unload_dedup[$_] -and ($post_unload_dedup[$_] = $true)
            }) -join $path_sep

            # Ensure VCPKG_ROOT is in the baseline so -unload preserves it.
            if ($vcpkg_root_trimmed -and -not $post_unload_dedup[$vcpkg_root_trimmed]) {
                $post_unload_path += $path_sep + $vcpkg_root_trimmed
            }
            $script:vsenv_vcpkg_in_path = $vcpkg_root_trimmed

            if (-not $arch) { $arch = $default_arch }

            # Normalize x64/amd64 synonyms before comparing to default_arch.
            $canon_arch = if ($arch -ieq 'x64') { 'amd64' }
                          elseif ($arch -ieq 'amd64') { 'x64' }
                          else { $arch }

            $vcvars_args = @($(if ($canon_arch -ieq $default_arch -or $arch -ieq $default_arch) {
                $arch
            } else {
                "${default_arch}_${arch}"
            }))

            if ($toolkit) {
                # Convert vXYZ (e.g. v143, v145) to an exact installed MSVC version.
                # vcvarsall -vcvars_ver needs a numeric prefix. VS2022 ships v143 as both
                # MSVC 14.3x and 14.4x, so "14.3" would silently miss 14.4x installs.
                # We scan VC\Tools\MSVC\ for the latest version in the expected range.
                if ($toolkit -match '^v(\d{2})(\d+)$') {
                    $tk_major = [int]$matches[1]  # 14
                    $tk_gen   = [int]$matches[2]  # 3 for v143
                    $lower = $tk_gen * 10       # v143 → 30
                    $upper = $tk_gen * 10 + 20  # v143 → 50 (exclusive)
                    $msvc_base = (resolve-path (join-path (split-path $vcvarsall.path -parent) '../../Tools/MSVC') -ea ignore).path
                    $best = if ($msvc_base) {
                        get-childitem $msvc_base -directory |
                            ?{ $_.name -match '^(\d+)\.(\d+)\.' -and
                               [int]$matches[1] -eq $tk_major -and
                               [int]$matches[2] -ge $lower -and
                               [int]$matches[2] -lt $upper } |
                            sort name | select -last 1
                    }
                    $toolkit = if ($best) { $best.name } else { "$tk_major.$tk_gen" }
                }
                $vcvars_args += "-vcvars_ver=$toolkit"
            }

            $saved_vcpkg_root = $env:VCPKG_ROOT

            $list_vars | ?{ $_ -ine 'PATH' } | %{ remove-item -literalpath "env:$_" -ea ignore }

            $vcvars_cmd = "$vcvarsall $($vcvars_args -join ' ')"
            write-verbose "vsenv: $vcvars_cmd"

            $output = cmd /c "`"$vcvarsall`" $($vcvars_args -join ' ') && set" 2>&1

            if ($lastexitcode) {
                write-error "vcvarsall.bat failed with exit code $lastexitcode" -ea stop
            }

            # Print vcvarsall banner/status lines (not VAR=value lines) as verbose.
            $output | ?{ $_ -and $_ -notmatch '^[A-Za-z_][A-Za-z_0-9]*=' } | %{
                write-verbose "vcvarsall: $_"
            }

            # saved_lists is the clean baseline restored on next unload.
            # PATH: use post-unload (no VS entries).
            # LIB/INCLUDE/LIBPATH: start from pre-unload (which has user additions
            # like vcpkg), then subtract what vcvarsall added last time so that
            # arch-specific VS/WinKits entries don't carry over across arch switches.
            $saved_lists = @{}
            $saved_lists['PATH'] = $post_unload_path
            foreach ($lv in $list_vars | ?{ $_ -ine 'PATH' }) {
                $val = $pre_unload[$lv]
                $saved_lists[$lv] = if ($val -and $prev_additions -and $prev_additions[$lv]) {
                    $added = $prev_additions[$lv]
                    $clean = $val -split $path_sep | %{ $_.trim().trimend('/\') } | ?{
                        $_ -and -not $added[$_]
                    }
                    if ($clean) { $clean -join $path_sep }
                } else {
                    $val
                }
            }

            # Rewrite vcpkg LIB/INCLUDE entries to the target architecture.
            # e.g. .../installed/x64-windows-static/lib -> .../arm64-windows-static/lib
            if ($env:VCPKG_ROOT) {
                $vcpkg_arch     = if ($arch -iin @('x64', 'amd64')) { 'x64' } else { $arch }
                $vcpkg_root_norm = ($env:VCPKG_ROOT -replace '[/\\]+', '\').trimend('\')
                $vcpkg_root_re   = [regex]::Escape($vcpkg_root_norm)
                foreach ($lv in @('LIB', 'INCLUDE')) {
                    $val = $saved_lists[$lv]
                    if (-not $val) { continue }
                    $saved_lists[$lv] = ($val -split $path_sep | %{
                        $e = $_ -replace '[/\\]+', '\'
                        if ($e -imatch "^${vcpkg_root_re}\\installed\\[^\\]+-windows(-static)?\\(lib|include)$") {
                            "$env:VCPKG_ROOT/installed/${vcpkg_arch}-windows$($matches[1])/$($matches[2])"
                        } else { $_ }
                    }) -join $path_sep
                }
            }

            $state = @{
                saved_lists         = $saved_lists
                vars                = @{}
                vcvarsall_additions = @{}
            }

            $output | ?{ $_ -match '^([^=]+)=(.*)$' } | %{
                $name  = $matches[1]
                $value = $matches[2]

                if ($list_vars -icontains $name) {
                    # Record everything vcvarsall outputs for LIB/INCLUDE/LIBPATH so
                    # the next call can subtract these arch-specific entries from pre_unload.
                    if ($name -ine 'PATH') {
                        $vc_set = @{}
                        $value -split $path_sep | %{
                            $n = ($_ -replace '[/\\]{2,}', '\').trim().trimend('\')
                            if ($n) { $vc_set[$n] = $true }
                        }
                        $state.vcvarsall_additions[$name] = $vc_set
                    }

                    $saved = $state.saved_lists[$name]
                    # saved is the user baseline; split into entries for merging.
                    # Strip VS/SDK/WinKits/.NET paths that may have leaked in.
                    $saved_entries = @($saved -split $path_sep | %{ $_.trim().trimend('/\') } | ?{
                        $_ -and $_ -inotmatch $vs_strip_re
                    })
                    # Build a set of all saved entry identities: both resolved path and
                    # raw string, so deduplication works whether or not the directory
                    # exists.  Entries are pre-normalized (trimmed, no trailing slash).
                    $seen = @{}
                    $saved_entries | %{
                        $rp = (resolve-path $_ -ea ignore).path
                        if ($rp) { $seen[$rp.trim().trimend('/\')] = $true }
                        $seen[$_] = $true
                    }
                    $new_entries = @($value -split $path_sep | %{ ($_ -replace '[/\\]{2,}', '\').trim().trimend('/\') } | ?{
                        if (-not $_) { return $false }
                        $rp    = (resolve-path $_ -ea ignore).path
                        $check = if ($rp) { $rp.trim().trimend('/\') } else { $_ }
                        -not $seen[$check]
                    })
                    # Replace VS-bundled vcpkg (...\VC\vcpkg) with $env:VCPKG_ROOT.
                    if ($name -ieq 'PATH' -and $env:VCPKG_ROOT) {
                        $new_entries = @($new_entries | %{
                            if ($_ -imatch '[/\\]VC[/\\]vcpkg$') { $env:VCPKG_ROOT } else { $_ }
                        })
                    }
                    if ($name -ieq 'PATH') {
                        # Record the entries appended to PATH, so the unload
                        # above can subtract exactly these on the next call.
                        # VCPKG_ROOT is part of the baseline, not an addition.
                        $vc_set = @{}
                        $new_entries | ?{ $_ -ine $vcpkg_root_trimmed } | %{
                            $n = $_.trim().trimend('/\')
                            if ($n) { $vc_set[$n] = $true }
                        }
                        $state.vcvarsall_additions['PATH'] = $vc_set
                    }
                    # PATH: append VS entries after base entries.
                    # LIB/INCLUDE/LIBPATH: VS entries first, user additions after.
                    $all_entries = if ($name -ieq 'PATH') {
                        @($saved_entries) + @($new_entries)
                    } else {
                        @($new_entries) + @($saved_entries)
                    }
                    # Final deduplication pass (first occurrence wins).
                    $dedup_seen = @{}
                    $all_entries = @($all_entries | ?{ -not $dedup_seen[$_] -and ($dedup_seen[$_] = $true) })
                    if ($all_entries) {
                        set-item -literalpath "env:$name" ($all_entries -join $path_sep)
                    }
                }
                elseif ($name -like '__VSCMD_PREINIT_*') {
                    # vcvarsall records pre-call values of VS vars as __VSCMD_PREINIT_*
                    # when it finds them already set (e.g. inherited from a parent shell).
                    # vsenv manages its own state so these are unnecessary; discard them.
                    remove-item -literalpath "env:$name" -ea ignore
                }
                elseif ($name -ine 'VCPKG_ROOT') {
                    # VCPKG_ROOT is managed separately via $saved_vcpkg_root; excluding it
                    # here prevents the unload phase from clobbering it between vsenv calls.
                    $state.vars[$name] = (get-item -literalpath "env:$name" -ea ignore).value
                    set-item -literalpath "env:$name" $value
                }
            }

            if ($saved_vcpkg_root) {
                $env:VCPKG_ROOT = $saved_vcpkg_root
            }

            if ($toolkit -and -not $env:VCToolsVersion) {
                write-warning "vsenv: toolset '$toolkit' was not selected by vcvarsall. Run with -verbose to see vcvarsall output."
            }

            $script:vsenv_state = $state
        }
    }
}

# vcpkg-list and vcpkg-mkpkg live in their own repo.
# setup_build_env pulls them in, once per session.
function update_binpkg_module {
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

function update_vcpkg([string]$toolkit = '') {
    $vcpkg_dir  = if ($toolkit) { $env:VCPKG_ROOT.TrimEnd('/\') + "-$toolkit" } else { $env:VCPKG_ROOT }
    $vcpkg_name = split-path -leaf $vcpkg_dir

    if (-not (test-path $vcpkg_dir)) {
	pushd $REPOS_ROOT

	git clone git@github.com:microsoft/vcpkg $vcpkg_name

	popd
    }

    if (-not (test-path $vcpkg_dir/.git)) {
	pushd $vcpkg_dir

	git init
	git remote add origin https://github.com/microsoft/vcpkg.git
	git fetch --all --prune
	git reset --hard origin/master
	git branch --set-upstream-to=origin/master master

	popd
    }

    pushd $vcpkg_dir

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
}

$script:current_arch      = $null
$script:current_toolchain = $null
$script:current_toolkit   = $null
$script:updated_toolkits  = @{}
$script:updated_binpkg    = $false

function rewrite_vcpkg_root([string]$old_root, [string]$new_root) {
    set-alias -force -scope global vcpkg (join-path $new_root $(if ($iswindows) { 'vcpkg.exe' } else { 'vcpkg' }))

    if (-not $old_root -or $old_root -ieq $new_root) { return }

    $old_re = [regex]::Escape(($old_root -replace '[/\\]+', '\').trimend('\'))

    foreach ($lv in 'LIB', 'INCLUDE') {
        $val = (get-item -literalpath "env:$lv" -ea ignore).value
        if (-not $val) { continue }
        set-item -literalpath "env:$lv" (
            ($val -split $path_sep | %{
                $e = $_ -replace '[/\\]+', '\'
                if ($e -imatch "^${old_re}(?=[/\\])") { $new_root + ($e -replace "^${old_re}", '') }
                else { $_ }
            }) -join $path_sep
        )
    }
}

function setup_build_env([string]$triplet, [string]$toolkit = '') {
    # Before the early return below: the packaging commands are wanted on every
    # platform, and off Windows this is the only part of the setup that runs.
    if (-not $script:updated_binpkg) {
        $script:updated_binpkg = $true
        update_binpkg_module
    }

    if (-not $iswindows) { return }

    $triplet -match '^([^-]+)-([^-]+)' | out-null
    $arch      = $matches[1]
    $toolchain = $matches[2]

    if (-not $script:updated_toolkits[$toolkit]) {
        $script:updated_toolkits[$toolkit] = $true
        update_vcpkg $toolkit
    }

    if (($arch -eq $script:current_arch) -and ($toolchain -eq $script:current_toolchain) -and ($toolkit -eq $script:current_toolkit)) { return }

    $script:current_arch      = $arch
    $script:current_toolchain = $toolchain
    $script:current_toolkit   = $toolkit

    restore_env
    save_env

    $old_vcpkg_root = $env:VCPKG_ROOT
    if ($toolkit) { $env:VCPKG_ROOT = $env:VCPKG_ROOT.TrimEnd('/\') + "-$toolkit" }
    rewrite_vcpkg_root $old_vcpkg_root $env:VCPKG_ROOT

    if ($toolkit) {
        $env:VCPKG_OVERLAY_TRIPLETS = $env:VCPKG_OVERLAY_PORTS + "/triplets-$toolkit"
    }

    if ($triplet -match 'mingw') {
	if ($arch -eq 'x86') {
	    $env:Path = 'c:/msys64/mingw32/bin;' + $env:Path
	}
	elseif ($arch -eq 'x64') {
	    $env:Path = 'c:/msys64/clang64/bin;' + $env:Path
	}
    }
    else { # MSVC
	vsenv $arch $toolkit
    }
}

function teardown_build_env {
    $old_vcpkg_root = $env:VCPKG_ROOT
    restore_env
    rewrite_vcpkg_root $old_vcpkg_root $env:VCPKG_ROOT
    $script:vsenv_state       = $null
    $script:current_arch      = $null
    $script:current_toolchain = $null
    $script:current_toolkit   = $null
    $script:updated_toolkits.clear()
    # $script:updated_binpkg is deliberately not reset: an imported module is
    # not part of the environment restore_env puts back, so a later
    # setup_build_env would only re-clone and re-import what is already here.
}

function get-triplets {
    if ($myinvocation.expectinginput) { $args = @($input) }

    $toolkit     = ''
    $android     = $false
    $triplet_args = @()
    for ($i = 0; $i -lt $args.count; $i++) {
        if     ($args[$i] -match '^--?android$')                             { $android = $true }
        elseif ($args[$i] -match '^--?toolkit=(.+)')                         { $toolkit = $matches[1] }
        elseif ($args[$i] -match '^--?toolkit$'  -and $i+1 -lt $args.count) { $toolkit = $args[++$i] }
        elseif ($args[$i] -match '^--?triplets?=(.+)')                       { $triplet_args = @($matches[1] -split '[,\s]+' | ?{ $_ }) }
        elseif ($args[$i] -match '^--?triplets?$') {
            while ($i+1 -lt $args.count -and $args[$i+1] -notmatch '^-') { $triplet_args += $args[++$i] -split '[,\s]+' | ?{ $_ } }
        }
        # -f/--force is the callers' own: vcpkg-daily.ps1 and build-nightly.ps1
        # each read it off their $args and then forward the lot here, so accept
        # and ignore it rather than making every caller filter it out first.
        elseif ($args[$i] -match '^--?f(orce)?$')                            { }
        else {
            # Anything else is a mistake, not something to drop. This loop used
            # to ignore what it did not recognize, so "--tolkit v143" left the
            # toolkit unset and every x86/x64 Windows triplet kept its default
            # pair -- the run built both toolsets, twice the work asked for,
            # and said nothing about why.
            write-error ("get-triplets: unknown argument '" + $args[$i] + "'; expected --triplets, --toolkit, --android or --force") -ea stop
        }
    }

    $requested_triplets = $triplet_args | %{ $_.tolower() } | %{
        if ($_ -match '^(x[86][64]|arm64)$') {
            "$_-windows-static"
        }
        elseif ($_ -match '^(x[86]|[64])-mingw$') {
            "$_-mingw-static"
        }
        else {
            $_
        }
    } | select -unique

    # Which triplets a toolkit other than the default is defined for. The
    # filter just below and the assignment further down both need to agree on
    # that, so say it once.
    $toolkit_triplet_re = '^x(64|86)-windows(-static)?$'

    if (-not $requested_triplets) {
        # --toolkit on its own means "the triplets that toolkit is for", not
        # "all of them, built with it". A mingw or arm64 triplet has no v143
        # to select, and building one under a toolkit that does not apply to
        # it is never what was meant.
        $requested_triplets = if ($toolkit) {
            @($TRIPLETS | ?{ $_ -match $toolkit_triplet_re })
        } else {
            $TRIPLETS
        }
    }

    if ($android) {
        if (-not ($islinux -or $ismacos)) {
            write-error 'the Android triplets are only built on Linux and macOS' -ea stop
        }

        $requested_triplets = @($requested_triplets) + @($ANDROID_TRIPLETS) | select -unique
    }

    # Every triplet actually about to be built has to support the toolkit that
    # was asked for. Naming one that does not is a mistake worth stopping on
    # rather than building under a toolkit that means nothing to it: only the
    # default list is filtered above, on the grounds that naming triplets says
    # which are wanted, so this is where an explicit --triplets gets checked.
    if ($toolkit) {
        $unsupported = @($requested_triplets | ?{ $_ -notmatch $toolkit_triplet_re })

        if ($unsupported) {
            write-error ("get-triplets: toolkit '" + $toolkit + "' does not apply to: " + ($unsupported -join ', ')) -ea stop
        }
    }

    foreach ($t in $requested_triplets) {
        $tks = if ($toolkit) {
            @($toolkit)
        } elseif ($t -match $toolkit_triplet_re) {
            @('', 'v143')
        } else {
            @('')
        }
        $obj = [PSCustomObject]@{ Triplet = $t; Toolkits = $tks }
        $obj | add-member -membertype scriptmethod -name ToString -value { $this.Triplet } -force
        $obj
    }
}

# The port list a triplet wants: Android takes the cross list, everything else
# the host's own. Callers pass the triplet object or its name.
function get_dep_ports([string]$triplet = '') {
    if ($triplet -match '-android$') { $ANDROID_DEP_PORTS } else { $DEP_PORTS }
}

# The host packages a build of $triplets puts on $host_triplet, as vcpkg
# install specs: the port name plus whatever features the plan asks for. Every
# triplet is planned with its own port list and the results are unioned, so
# asking about all five Android triplets at once gives the set any of them
# needs.
#
# Two things want this. A host triplet builds the Android host halves: moc, rcc
# and androiddeployqt run on the build machine, so vcpkg builds qtbase and
# qttools for the host while building them for the target, and no desktop build
# asks for either -- a host that only ever built the desktop list has no host Qt
# to hand an Android build that lands on it, and compiles one from source first.
# The Android targets themselves are built on Linux and macOS under --android;
# these are the host halves of that build, wanted on every host the platform
# defines whether or not that host ever builds the targets. A cross-compiled
# target wants the same for the machine it is cross-compiled *for*: an
# arm64-windows-static build hosted on an arm64 machine needs vcpkg-cmake,
# pkgconf and the rest built for arm64-windows.
#
# The set comes out of vcpkg's own install plan rather than a list here, so the
# ports tree's host edges, features and platform gates are read the way the
# build itself reads them, the whole graph is covered rather than the named
# ports alone -- icu arrives under qtbase and asks for icu on the host to
# cross-build its data, and nobody names icu -- and a new host dependency
# arrives on its own. --dry-run computes that plan without building anything
# and without an NDK, which is what makes this usable on a host that has
# neither.
#
# $plan_for is where the plan comes from, one triplet at a time. It is a
# parameter so the parsing below can be checked against a captured plan
# without a vcpkg to run; nothing but the tests passes it.
function get_host_ports([string[]]$triplets, [string]$host_triplet, [scriptblock]$plan_for = $null) {
    # The plan is captured with 2>&1 so a failure can be reported with what
    # vcpkg said about it. Under Windows PowerShell -- which is what the
    # scheduled task runs -- a native command's redirected stderr becomes an
    # error record, and the caller's erroractionpreference of stop turns the
    # first one of those into a terminating error, so a triplet vcpkg merely
    # grumbled about would take the whole nightly down instead of the warning
    # below. This is scoped to the function and restored on the way out.
    $erroractionpreference = 'continue'

    # riscv64-android has no triplet in vcpkg itself, only in the overlay, and
    # on Windows VCPKG_OVERLAY_TRIPLETS points at the per-toolkit directory
    # instead. Name the overlay's own triplets directory for the plan so all
    # five Android triplets resolve on every platform: vcpkg reads this
    # alongside the environment, and repeating a directory it already has
    # changes nothing.
    $overlay_triplets = join-path `
        $(if ($env:VCPKG_OVERLAY_PORTS) { $env:VCPKG_OVERLAY_PORTS } else { $OVERLAY_PORTS }) `
        'triplets/community'

    $overlay_args = if (test-path $overlay_triplets) { @('--overlay-triplets', $overlay_triplets) } else { @() }

    # Planned against an install root of its own, which stays empty because
    # --dry-run never writes packages into one. vcpkg leaves an already
    # installed package out of a plan entirely unless it was named on the
    # command line -- it treats one as satisfied whatever version it is -- so
    # read against the real tree this returns everything that is missing today
    # and nothing that was built yesterday. The host Qt would then drop out of
    # the port list the run after it was first built, stop being upgraded by
    # name, and sit at that version for good. Against an empty root the answer
    # is the whole set every time, which is the question being asked: what does
    # a build of this put on that host.
    $plan_root = join-path $env:TEMP 'vbam-host-plan-root'

    if (-not $plan_for) {
        $plan_for = {
            param($t)

            $ports = @(get_dep_ports $t)

            vcpkg install --dry-run @overlay_args --x-install-root=$plan_root `
                --triplet $t --host-triplet $host_triplet `
                --allow-unsupported --recurse @ports 2>&1
        }
    }

    $features = [ordered]@{}

    foreach ($t in $triplets) {
        $plan = & $plan_for $t

        # One triplet vcpkg cannot plan is not worth failing a nightly over:
        # riscv64-android is the one that can go missing, and the host set
        # barely differs between Android architectures, so the others cover it.
        # Name the triplet anyway, so one that quietly stops resolving is still
        # visible in the log.
        if ($lastexitcode -ne 0) {
            write-warning ("could not compute the $t host deps for ${host_triplet}: " +
                           ((@($plan | %{ "$_" }) -join "`n").trim()))
            continue
        }

        foreach ($line in $plan) {
            # "  * icu[core,tools]:x64-windows@78.3#2", with " -- <port dir>"
            # after the version for an overlay port. Both the packages the plan
            # would build and the ones it reports already installed are wanted:
            # naming an installed one is what keeps it upgraded and packaged.
            if ("$line" -notmatch ('^\s*\*?\s*([^\s:\[\]]+)(?:\[([^\]]*)\])?:' +
                                   [regex]::escape($host_triplet) + '@')) { continue }

            $port = $matches[1]
            $fs   = @($matches[2] -split ',' | %{ $_.trim() } | ?{ $_ })

            if (-not $features.contains($port)) { $features[$port] = [ordered]@{} }

            # "core" in a plan means the port's default features were turned
            # off, and "platform-default-features" is how it writes the ones it
            # kept. Neither belongs in a spec installed on its own here: what
            # is wanted is the port's own defaults plus the extras the Android
            # plan named -- icu's tools, say -- so that a port some other list
            # already asked for only ever gains a feature, where a spec
            # carrying core would take that list's features back off it.
            foreach ($f in @($fs | ?{ $_ -notin 'core','platform-default-features' })) {
                $features[$port][$f] = $true
            }
        }
    }

    foreach ($port in $features.keys) {
        if ($features[$port].count) { "$port[$(@($features[$port].keys) -join ',')]" } else { $port }
    }
}

function get_host_triplet {
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'Arm64' { 'arm64' }
        'X64'   { 'x64' }
        default { 'x64' }
    }
    if ($iswindows) { "$arch-windows" }
    elseif ($islinux) { "$arch-linux" }
    elseif ($ismacos) { "$arch-osx" }
}

export-modulemember -variable ROOT,REPOS_ROOT,DEP_PORTS,DEP_PORT_NAMES,ANDROID_DEP_PORTS,ANDROID_DEP_PORT_NAMES,ALL_DEP_PORT_NAMES,ANDROID_TRIPLETS,HOST_TRIPLETS,OVERLAY_PORTS `
		    -function setup_build_env,teardown_build_env,get-triplets,get_host_triplet,get_dep_ports,get_host_ports `
		    -alias vcpkg
