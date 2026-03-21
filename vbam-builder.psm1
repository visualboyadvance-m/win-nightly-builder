[system.globalization.cultureinfo]::currentculture = 'en-US'

[console]::outputencoding = [console]::inputencoding = `
    $outputencoding = new-object system.text.utf8encoding

$ROOT           = $(if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME })

$REPOS_ROOT     = $ROOT + '/source/repos'

$DEP_PORTS      = echo zlib bzip2 'liblzma[tools]' 'sdl3[vulkan]' faudio gettext-libintl nanosvg 'wxwidgets[core]' openal-soft 'ffmpeg[x264,x265]'

if ($islinux -or $ismacos) {
    $DEP_PORTS = @('pthreads')      + $DEP_PORTS
}
elseif ($iswindows) {
    $DEP_PORTS = @('pthread-stubs') + $DEP_PORTS
}

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

if ((test-path '/program files/git/cmd') -and ($env:Path -notmatch '[/\\]git[/\\]cmd')) {
    $env:Path += ';' + (resolve-path '/program files/git/cmd')
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
            $pre_unload = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($lv in $list_vars) {
                $pre_unload[$lv] = (get-item -literalpath "env:$lv" -ea ignore).value
            }

            # Grab the record of what vcvarsall added last session before we clear state.
            $prev_additions = if ($script:vsenv_state) { $script:vsenv_state.vcvarsall_additions } else { $null }

            # Unload previous vsenv state.
            if ($script:vsenv_state) {
                # Restore PATH and list vars (INCLUDE, LIB, LIBPATH).
                $script:vsenv_state.saved_lists.getenumerator() | %{
                    if ($null -ne $_.value) {
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

            # Regex matching VS/SDK/WinKits/.NET/.NET-adjacent PATH entries added by
            # vcvarsall, used to strip the inherited PATH when starting a new shell
            # that already has a vsenv'd PATH from its parent process.
            $vs_strip_re = '[/\\]Microsoft Visual Studio[/\\]|[/\\]Microsoft SDKs[/\\]|[/\\]Windows Kits[/\\](?:[^/\\]+[/\\](?:bin|lib|include|UnionMetadata|References)[/\\]|NETFXSDK[/\\])|[/\\]Microsoft\.NET[/\\]|[/\\]HTML Help Workshop'

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
            $post_unload_dedup = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            $post_unload_path = ($env:Path -split $path_sep | %{ $_.trim().trimend('/\') } | ?{
                $_ -and $_ -inotmatch $vs_strip_re -and $post_unload_dedup.add($_)
            }) -join $path_sep

            # Ensure VCPKG_ROOT is in the baseline so -unload preserves it.
            if ($vcpkg_root_trimmed -and -not $post_unload_dedup.contains($vcpkg_root_trimmed)) {
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
            $saved_lists = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
            $saved_lists['PATH'] = $post_unload_path
            foreach ($lv in $list_vars | ?{ $_ -ine 'PATH' }) {
                $val = $pre_unload[$lv]
                $saved_lists[$lv] = if ($val -and $prev_additions -and $prev_additions[$lv]) {
                    $added = $prev_additions[$lv]
                    $clean = $val -split $path_sep | %{ $_.trim().trimend('/\') } | ?{
                        $_ -and -not $added.contains($_)
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
                vcvarsall_additions = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
            }

            $output | ?{ $_ -match '^([^=]+)=(.*)$' } | %{
                $name  = $matches[1]
                $value = $matches[2]

                if ($list_vars -icontains $name) {
                    # Record everything vcvarsall outputs for LIB/INCLUDE/LIBPATH so
                    # the next call can subtract these arch-specific entries from pre_unload.
                    if ($name -ine 'PATH') {
                        $vc_set = [System.Collections.Generic.HashSet[string]]::new(
                            [System.StringComparer]::OrdinalIgnoreCase)
                        $value -split $path_sep | %{
                            $n = ($_ -replace '[/\\]{2,}', '\').trim().trimend('\')
                            if ($n) { [void]$vc_set.add($n) }
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
                    $seen = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                    $saved_entries | %{
                        $rp = (resolve-path $_ -ea ignore).path
                        if ($rp) { [void]$seen.add($rp.trim().trimend('/\')) }
                        [void]$seen.add($_)
                    }
                    $new_entries = @($value -split $path_sep | %{ ($_ -replace '[/\\]{2,}', '\').trim().trimend('/\') } | ?{
                        if (-not $_) { return $false }
                        $rp    = (resolve-path $_ -ea ignore).path
                        $check = if ($rp) { $rp.trim().trimend('/\') } else { $_ }
                        -not $seen.contains($check)
                    })
                    # Replace VS-bundled vcpkg (...\VC\vcpkg) with $env:VCPKG_ROOT.
                    if ($name -ieq 'PATH' -and $env:VCPKG_ROOT) {
                        $new_entries = @($new_entries | %{
                            if ($_ -imatch '[/\\]VC[/\\]vcpkg$') { $env:VCPKG_ROOT } else { $_ }
                        })
                    }
                    # PATH: append VS entries after base entries.
                    # LIB/INCLUDE/LIBPATH: VS entries first, user additions after.
                    $all_entries = if ($name -ieq 'PATH') {
                        @($saved_entries) + @($new_entries)
                    } else {
                        @($new_entries) + @($saved_entries)
                    }
                    # Final deduplication pass (first occurrence wins).
                    $dedup_seen = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase)
                    $all_entries = @($all_entries | ?{ $dedup_seen.add($_) })
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
$script:current_toolkit   = $null
$script:updated_toolkits  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

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
    if (-not $iswindows) { return }

    $triplet -match '^([^-]+)-([^-]+)' | out-null
    $arch      = $matches[1]
    $toolchain = $matches[2]

    if ($script:updated_toolkits.add($toolkit)) {
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
}

function get-triplets {
    if ($myinvocation.expectinginput) { $args = @($input) }

    $toolkit     = ''
    $triplet_args = @()
    for ($i = 0; $i -lt $args.count; $i++) {
        if     ($args[$i] -match '^--?toolkit=(.+)')                         { $toolkit = $matches[1] }
        elseif ($args[$i] -match '^--?toolkit$'  -and $i+1 -lt $args.count) { $toolkit = $args[++$i] }
        elseif ($args[$i] -match '^--?triplets?=(.+)')                        { $triplet_args = $matches[1] -split ',' }
        elseif ($args[$i] -match '^--?triplets?$' -and $i+1 -lt $args.count) { $triplet_args = $args[++$i] -split ',' }
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

    if (-not $requested_triplets) { $requested_triplets = $TRIPLETS }

    foreach ($t in $requested_triplets) {
        $tks = if ($toolkit) {
            @($toolkit)
        } elseif ($t -match '^x(64|86)-windows(-static)?$') {
            @('', 'v143')
        } else {
            @('')
        }
        $obj = [PSCustomObject]@{ Triplet = $t; Toolkits = $tks }
        $obj | add-member -membertype scriptmethod -name ToString -value { $this.Triplet } -force
        $obj
    }
}

export-modulemember -variable ROOT,REPOS_ROOT,DEP_PORTS,DEP_PORT_NAMES `
		    -function setup_build_env,teardown_build_env,get-triplets `
		    -alias vcpkg
