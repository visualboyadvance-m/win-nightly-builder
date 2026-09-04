import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$stage_dir = "$env:TEMP/vbam-daily-packages"

$packages      = $null
$skip_packages = @()
$filtered_args = @()
for ($i = 0; $i -lt $args.count; $i++) {
    if     ($args[$i] -match '^--?packages?=(.+)')          { $packages      = @($matches[1] -split '[,\s]+' | ?{ $_ }) }
    elseif ($args[$i] -match '^--?packages?$')              {
        $packages = @()
        while ($i+1 -lt $args.count -and $args[$i+1] -notmatch '^-') { $packages += $args[++$i] -split '[,\s]+' | ?{ $_ } }
    }
    elseif ($args[$i] -match '^--?skip[-_]?packages?=(.+)')    { $skip_packages = @($matches[1] -split '[,\s]+' | ?{ $_ }) }
    elseif ($args[$i] -match '^--?skip[-_]?packages?$')        {
        $skip_packages = @()
        while ($i+1 -lt $args.count -and $args[$i+1] -notmatch '^-') { $skip_packages += $args[++$i] -split '[,\s]+' | ?{ $_ } }
    }
    else   { $filtered_args += $args[$i] }
}

$force_build = if ($filtered_args[0] -match '^--?f') { $true} else { $false }

$build_triplets = get-triplets @filtered_args

if ($packages) {
    $unknown = $packages | ?{ $_ -notin $ALL_DEP_PORT_NAMES }
    if ($unknown) { write-error "Unknown package(s): $($unknown -join ', ')" -ea stop }
}
if ($skip_packages) {
    $unknown = $skip_packages | ?{ $_ -notin $ALL_DEP_PORT_NAMES }
    if ($unknown) { write-error "Unknown skip package(s): $($unknown -join ', ')" -ea stop }
}

# Which ports a triplet wants is a property of the triplet, not of the host:
# an Android triplet takes the cross list, everything else the host's own. The
# --packages/--skip-packages filters then apply to whichever list that is.
function selected_ports([string]$triplet) {
    $ports = get_dep_ports $triplet
    if ($packages)      { $ports = $ports | ?{ ($_ -replace '\[[^\]]+\]','') -in $packages } }
    if ($skip_packages) { $ports = $ports | ?{ ($_ -replace '\[[^\]]+\]','') -notin $skip_packages } }
    @($ports)
}

$selected_port_names = @($build_triplets | %{ selected_ports $_ }) -replace '\[[^\]]+\]','' | select-object -unique

"INFO: vcpkg packages upgrade started on $(date)."

# set-content ends lines the way the platform does, so a Windows builder
# rewriting a port file turns every line of it CRLF: the whole file reads as
# changed, and the overlay ends up carrying both endings depending on which
# builder got to the update first. Write LF whatever the platform, which is
# what the overlay's files are.
function set_content_lf([string]$path, [string[]]$lines) {
    [io.file]::WriteAllText((convert-path $path), (($lines -join "`n") + "`n"))
}

if ('wxwidgets' -in $selected_port_names) {
    $temp_dir = "$env:TEMP/wx-port-temp"

    ni -it dir $temp_dir -ea ignore | out-null

    pushd $temp_dir

    curl -LO https://github.com/wxWidgets/wxWidgets/archive/master.tar.gz

    $new_wx_hash = (get-filehash -a sha512 master.tar.gz).hash.tolower()

    popd

    ri -r -fo $temp_dir

    pushd $(if ($env:VCPKG_OVERLAY_PORTS) { $env:VCPKG_OVERLAY_PORTS } else { $OVERLAY_PORTS })

    # Every builder runs this, so pick up whichever one got here first: the hash
    # check below then sees its commit and there is nothing left to do.
    git pull --rebase --autostash

    if (-not ((gc wxwidgets/portfile.cmake) -match $new_wx_hash)) {
        set_content_lf wxwidgets/portfile.cmake `
            @(gc wxwidgets/portfile.cmake | %{ $_ -replace 'SHA512 .*',"SHA512 $new_wx_hash" })

        $wx_master_ver = (
            iwr -usebasicparsing https://raw.githubusercontent.com/wxWidgets/wxWidgets/refs/heads/master/include/wx/version.h | % content |
            sls '.*wxVERSION_STRING\D+([\d.]+).*' | select -first 1
        ).matches.groups[1].value

        set_content_lf wxwidgets/vcpkg.json `
            @(gc wxwidgets/vcpkg.json | %{
                $(if ($_ -match '^(  "version": ")([^-]+)-(\d+)(".*)') {
                    $matches.1 + $wx_master_ver + '-' +
                    $(if ($matches.2 -ne $wx_master_ver) { 1 } `
                      else { [convert]::toint32($matches.3) + 1 }) +
                    $matches.4 } `
                else { $_ }) })

        git commit -a -m "wxwidgets: update master hash + bump ver" --signoff

        if ($lastexitcode -ne 0) {
            write-error 'failed to commit the wxwidgets port update in the overlay'
        }
        else {
            # Another builder can still have pushed between the pull above and
            # here, which leaves a non-fast-forward. Rebase onto it and retry
            # rather than failing the nightly over a lost race.
            $pushed = $false

            foreach ($try in 1..3) {
                git push

                if ($lastexitcode -eq 0) { $pushed = $true; break }

                "INFO: push rejected, rebasing onto the remote and retrying ($try)."
                git pull --rebase --autostash
            }

            if (-not $pushed) {
                write-error 'failed to push the wxwidgets port update to the overlay'
            }
        }
    }

    popd
}

# Build and generate binary packages

ri -r -fo  $stage_dir -ea ignore
ni -it dir $stage_dir -ea ignore | out-null

pushd $stage_dir

$extra_triplets     = @()
$added_target_hosts = @{}
$throttle           = [System.Environment]::ProcessorCount
$binpkg_module      = $null
# Ports whose packaging was skipped, filled in by the packing jobs below.
$pack_failures      = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
# Ports that never came out of the build at all.
$build_failures     = @()

foreach ($triplet in $build_triplets) {
    $build_ports      = selected_ports $triplet
    $build_port_names = @($build_ports -replace '\[[^\]]+\]','')

    foreach ($tk in $triplet.toolkits) {
        setup_build_env $triplet $tk

        if (-not $binpkg_module) { $binpkg_module = (get-module vcpkg-binpkg).path }
        $host_t = get_host_triplet

        foreach ($port in $build_ports) {
            vcpkg --triplet $triplet --host-triplet $host_t install --no-binarycaching --allow-unsupported --recurse --keep-going $port
        }

        foreach ($port in $build_port_names) {
            vcpkg --triplet $triplet --host-triplet $host_t upgrade --no-binarycaching --allow-unsupported --no-dry-run --keep-going $port
        }

        $pkg_subdir = if ($tk) { "$triplet/$tk" } else { $triplet }
        ni -it dir $pkg_subdir -ea ignore | out-null
        $pkg_subdir_abs = join-path $stage_dir $pkg_subdir
        $triplet_s      = "$triplet"
        $installed_names = @(vcpkg-list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' })

        # A port that failed to build was never installed, so vcpkg-list does
        # not mention it, so the packing pipeline below never sees it: no
        # package, and no failing job to warn from either. Nothing downstream
        # can tell that apart from a port that was never asked for, which is
        # how a failed ffmpeg:x86-mingw-static went out as a clean run. Diff
        # what was asked for against what came out installed and say the
        # difference out loud.
        foreach ($missing in @($build_port_names | ?{ $_ -notin $installed_names })) {
            $build_failures += "${missing}:$triplet$(if ($tk) { " ($tk)" })"
            write-warning "${missing}:$triplet did not build, nothing to package"
        }

        $installed_names | ?{ -not $packages -or $_ -in $build_port_names } | %{
            start-threadjob -throttlelimit $throttle -argumentlist $_ -scriptblock {
                param($_)
                # Held under another name: $_ is the error record inside the
                # catch below.
                $pkg       = $_
                $qualified = "${pkg}:$($using:triplet_s)"
                import-module $using:binpkg_module
                set-location $using:pkg_subdir_abs
                "Packing $pkg for $($using:triplet_s)$(if ($using:tk) { " ($($using:tk))" })..."
                try {
                    vcpkg-mkpkg $qualified
                }
                catch {
                    # A port that failed to build is not installed, so there is
                    # nothing to package for it and vcpkg-mkpkg says so as a
                    # terminating error -- which receive-job re-raises in the
                    # parent, where erroractionpreference is stop, and one
                    # broken port took the whole nightly with it. Skip that
                    # port instead: the other packages for this triplet still
                    # get published, and the previous version of this one stays
                    # up since nothing replaces it.
                    ri "${pkg}_*.zip" -fo -ea ignore
                    ($using:pack_failures).Add($qualified)
                    write-warning "skipping ${qualified}: packaging failed: $($_.exception.message)"
                }
            }
        } | receive-job -wait -autoremovejob

        # For cross-compiling triplets, build host-tool dependencies for the
        # target architecture's native host triplet (e.g. arm64-windows for an
        # arm64-windows-static target) so they are usable on the target machine.
        $is_android = "$triplet" -in $ANDROID_TRIPLETS

        if (-not $packages -and $host_t -and ($is_android -or (($triplet -split '-')[0] -ne ($host_t -split '-')[0]))) {
            if ($is_android) {
                # Android is never a host. Nothing on the device runs moc or
                # androiddeployqt, so there is no "<target arch>-<host os>"
                # machine to build host tools for -- deriving one the way the
                # branch below does would cross-build a Linux host's tool
                # closure, X11 and all, for an arm64-linux nobody consumes.
                # The host tools an Android build needs are the ones on the
                # machine doing the building, so stay on the host triplet.
                $target_host_t = $host_t
            }
            else {
                # Derive the native host triplet for the target arch: same OS as
                # the build host but the target's own architecture.
                $target_arch   = ($triplet.ToString() -split '-')[0]
                $host_os       = ($host_t -split '-')[1]
                $target_host_t = "$target_arch-$host_os"
            }

            # Every port installed for the triplet, not just the ones named in
            # the port list. A host dependency belongs to the port that declares
            # it, and the ones that matter here are declared by ports nobody
            # names: icu arrives under qtbase and asks for icu on the host to
            # cross-build its data, and vcpkg-instpkg on the consuming side
            # insists on the build dependencies of every zip it installs,
            # transitive ones included. Filtering to the named ports left those
            # unbuilt and unpublished, so a consumer restoring the target zip
            # was told its database was corrupt -- icu:arm64-android installed,
            # icu:x64-linux not -- and built a host icu to fix it.
            $installed = vcpkg-list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' }
            if ($installed) {
                $qualified = @($installed | %{ "${_}:$triplet" })

                # The host dependency that matters for Android is Qt: vcpkg
                # builds qtbase and qttools for the host while building them
                # for the target, and no desktop build asks for either, so
                # without this an Android builder has no host Qt to fetch.
                # -Direct stops there. The full closure is what a bare host
                # needs to build those tools from nothing, which is the right
                # answer for the cross-Windows targets below and the wrong one
                # here: under a host Qt it reaches the whole desktop stack --
                # fontconfig, dbus, libsystemd -- that the host already has and
                # no APK put there.
                $host_deps = @(
                    if ($is_android) { vcpkg-listhostdeps -Direct @qualified }
                    else             { vcpkg-listhostdeps         @qualified }
                ) | ?{ $_ } | select-object -unique

                if ($host_deps) {
                    $target_host_tks = @(get-triplets @filtered_args "--triplets=$target_host_t")[0].Toolkits

                    foreach ($th_tk in $target_host_tks) {
                        "Building host deps for $target_host_t$(if ($th_tk) { " ($th_tk)" }) (cross target: $triplet)..."
                        setup_build_env $target_host_t $th_tk
                        foreach ($dep in $host_deps) {
                            vcpkg --triplet $target_host_t --host-triplet $host_t install --no-binarycaching --allow-unsupported --recurse --keep-going $dep
                        }
                        foreach ($dep in $host_deps) {
                            vcpkg --triplet $target_host_t --host-triplet $host_t upgrade --no-binarycaching --allow-unsupported --no-dry-run --keep-going $dep
                        }

                        # What to build is the direct set; what to package is
                        # its closure.  A consumer restoring the host Qt needs
                        # what that Qt was built against -- libb2, md4c,
                        # double-conversion, egl, libpq, sqlite3 -- or
                        # vcpkg-instpkg prunes it as incomplete, prunes the
                        # target Qt that names it, and the build compiles Qt
                        # from source for both.  Those are installed here and
                        # never published, since only $host_deps was packaged.
                        #
                        # Computed after the install above, not beside
                        # $host_deps: the walk reads each host package's own
                        # dependencies out of the status file, so it stops at a
                        # host Qt that is not installed yet.
                        $host_pkg_deps = @(
                            if ($is_android) { vcpkg-listhostdeps @qualified }
                            else             { $host_deps }
                        ) | ?{ $_ } | select-object -unique

                        $th_subdir = if ($th_tk) { "$target_host_t/$th_tk" } else { $target_host_t }
                        ni -it dir $th_subdir -ea ignore | out-null
                        $th_subdir_abs = join-path $stage_dir $th_subdir
                        $th_installed = @(vcpkg-list | ?{ $_ -match (":$target_host_t" + '\s+\d') } | %{ $_ -replace ':.*','' })

                        # Same silent gap as the target packing above: a host
                        # dep that failed to build just is not in the list.
                        foreach ($missing in @($host_deps | ?{ $_ -notin $th_installed })) {
                            $build_failures += "${missing}:$target_host_t$(if ($th_tk) { " ($th_tk)" })"
                            write-warning "${missing}:$target_host_t did not build, nothing to package"
                        }

                        $th_installed | ?{ -not $is_android -or $_ -in $host_pkg_deps } | %{
                            start-threadjob -throttlelimit $throttle -argumentlist $_ -scriptblock {
                                param($_)
                                $pkg       = $_
                                $qualified = "${pkg}:$($using:target_host_t)"
                                import-module $using:binpkg_module
                                set-location $using:th_subdir_abs
                                "Packing $pkg for $($using:target_host_t)$(if ($using:th_tk) { " ($($using:th_tk))" })..."
                                try {
                                    vcpkg-mkpkg $qualified
                                }
                                catch {
                                    # Skip a host dep that failed to build, the
                                    # same as the target packing above.
                                    ri "${pkg}_*.zip" -fo -ea ignore
                                    ($using:pack_failures).Add($qualified)
                                    write-warning "skipping ${qualified}: packaging failed: $($_.exception.message)"
                                }
                            }
                        } | receive-job -wait -autoremovejob
                    }

                    if ((-not $added_target_hosts[$target_host_t]) -and ($target_host_t -notin @($build_triplets | %{ "$_" }))) {
                        $added_target_hosts[$target_host_t] = $true
                        $th_obj = [PSCustomObject]@{ Triplet = $target_host_t; Toolkits = $target_host_tks }
                        $th_obj | add-member -membertype scriptmethod -name ToString -value { $this.Triplet } -force
                        $extra_triplets += $th_obj
                    }
                }
            }
        }
    }
}

teardown_build_env

$build_triplets = @($build_triplets) + @($extra_triplets)

foreach ($triplet in $build_triplets) {
    foreach ($tk in $triplet.toolkits) {
        $pkg_subdir  = if ($tk) { "$triplet/$tk" } else { $triplet }
        $remote_dir  = "vcpkg/$(if ($tk) { "$triplet/$tk" } else { $triplet })"
        $pkg_subdir_abs = join-path $stage_dir $pkg_subdir
        # What is up there already, so the put below can clear the older
        # versions of it first.
        #
        # sftp writes "Connected to ..." to stderr and "Changing to: ..." plus
        # the echoed prompt to stdout, so with stderr discarded two header lines
        # arrive rather than three -- and skipping three took the first file
        # with them. That is the alphabetically first port in the directory,
        # which therefore never looked present and never had its older versions
        # removed: x64-linux collected two alsa packages that way, and a
        # consumer offered a choice of two took neither.
        #
        # Match the names instead of counting what comes before them, and ask
        # for one per line so a short name cannot share one.
        $existing_pkgs = @('ls -1' | sftp "sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/$remote_dir" 2>$null | %{
            if ($_ -match '^\s*([^_\s]+)_[^_\s]+_[^_\s]+\.zip\s*$') { $matches[1] }
        }) | select-object -unique
        gci $pkg_subdir_abs -filter '*.zip' | %{
            start-threadjob -throttlelimit 3 -argumentlist $_ -scriptblock {
                param($_)
                $zip_name = $_.Name
                $zip_full = $_.FullName
                $pkg      = $zip_name -replace '^([^_]+).*', '$1'
                $rdir     = $using:remote_dir

                # sftp reads this batch a line at a time, so write LF
                # whatever the builder: add-content ends lines the platform's
                # way, and a CR riding along on a put becomes part of the
                # remote file name. set_content_lf lives in the script scope,
                # which a thread job's runspace does not see, so write inline.
                $batch = new-temporaryfile
                $batch_lines = @()
                if ($pkg -in $using:existing_pkgs) {
                    $batch_lines += "rm $rdir/${pkg}_*"
                }
                $batch_lines += "put $zip_full $rdir/$zip_name"
                $batch_lines += "chmod 664 $rdir/$zip_name"

                [io.file]::WriteAllText($batch.FullName, (($batch_lines -join "`n") + "`n"))

                sftp -b $batch sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/
                remove-item $batch
            }
        } | receive-job -wait -autoremovejob
    }
}

popd

ri -r -fo $stage_dir

# Skipped ports are only a warning in the job that hit them, thousands of lines
# back in the log by now, so say plainly at the end what did not get published.
if ($build_failures) {
    "WARNING: did not build, no package published: $((@($build_failures) | sort-object -unique) -join ', ')"
}

if ($pack_failures.count) {
    "WARNING: packaging skipped for: $((@($pack_failures) | sort-object -unique) -join ', ')"
}

'INFO: vcpkg packages upgrade successful!'

# vim:sts=4 sw=4 et:
