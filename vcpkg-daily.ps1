import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

# start-threadjob is built into PowerShell 7 but is a gallery module for Windows
# PowerShell, which is what the scheduled tasks run. Say so here rather than
# after a night of building, which is where the first packing job would find out.
if (-not (get-command start-threadjob -ea ignore)) {
    # The gallery ships it under both names depending on the version.
    import-module microsoft.powershell.threadjob -ea ignore
    import-module threadjob -ea ignore

    if (-not (get-command start-threadjob -ea ignore)) {
        write-error "start-threadjob is not available: install-module threadjob -scope allusers"
    }
}

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

# The host halves of the Android cross builds, for a triplet that can host one.
# The targets themselves are built on Linux and macOS under --android and take
# their host tools from the machine doing the building; this is that same set of
# packages, built and published for every host this platform defines, so an
# Android build hosted on any of them -- x64-windows, arm64-windows and
# x86-windows on Windows, whichever of them this builder itself runs on -- can
# fetch its Qt tools instead of compiling them. No desktop build asks for any of
# it, which is why a default run has to name them.
function android_host_ports([string]$triplet) {
    if ("$triplet" -notin $HOST_TRIPLETS) { return @() }

    $ports = @(get_host_ports $ANDROID_TRIPLETS $triplet)

    # A port the triplet's own list already names keeps that list's spec: its
    # features are the ones the emulator's CMakeLists asks for, and naming one
    # port twice with two feature sets only has vcpkg rebuild it back and forth.
    $own   = @(get_dep_ports $triplet) -replace '\[[^\]]+\]',''
    $ports = $ports | ?{ ($_ -replace '\[[^\]]+\]','') -notin $own }

    # The same filters the triplet's own list gets: these are part of what a
    # host triplet builds, so --packages/--skip-packages select within them too.
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
    $temp_dir    = "$env:TEMP/wx-port-temp"
    $wx_tarball  = "$temp_dir/master.tar.gz"

    ni -it dir $temp_dir -ea ignore | out-null

    # Not curl: Windows PowerShell aliases that to invoke-webrequest, which has
    # no -LO, so this line died on a parameter it never saw the moment the
    # scheduled tasks moved off pwsh. invoke-webrequest is the one spelling both
    # shells agree on. Write to an absolute path rather than pushd'ing, since
    # -outfile resolves against the process directory, not the PowerShell one.
    iwr -usebasicparsing https://github.com/wxWidgets/wxWidgets/archive/master.tar.gz -outfile $wx_tarball

    $new_wx_hash = (get-filehash -a sha512 $wx_tarball).hash.tolower()

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
    foreach ($tk in $triplet.toolkits) {
        setup_build_env $triplet $tk

        if (-not $binpkg_module) { $binpkg_module = (get-module vcpkg-binpkg).path }
        $host_t = get_host_triplet

        $build_ports = @(selected_ports $triplet)

        # The default toolkit only. What these packages provide is build tools
        # -- moc, rcc, androiddeployqt -- that nothing links against, so which
        # toolset built them changes nothing about what they do, and a second
        # copy under v143 would only be another Qt build.
        #
        # Inside the toolkit loop even so: the set comes out of a vcpkg install
        # plan, and setup_build_env has just pointed VCPKG_ROOT at the tree
        # that plan should be read from.
        $android_host = @(if (-not $tk) { android_host_ports $triplet })

        if ($android_host) {
            "Adding the Android host deps to ${triplet}: $($android_host -join ', ')"
        }

        $build_ports      = $build_ports + $android_host
        $build_port_names = @($build_ports -replace '\[[^\]]+\]','')

        # The build tooling among what that added -- vcpkg-cmake and the other
        # script ports, pkgconf, ffmpeg-bin2c -- is built and packaged like the
        # rest of it but never upgraded by name. vcpkg upgrade rebuilds the port
        # it is given and every installed package that depends on it, and every
        # port declares the script ports as host dependencies, so upgrading one
        # for a host triplet rebuilds that entire tree -- ports no list names any
        # more included. A leftover sdl2 on the macOS builder, from a faudio that
        # has since moved to SDL3, was rebuilt and republished every night that
        # way. They come back fresh on their own the moment a port that needs a
        # newer one is rebuilt.
        #
        # Only what the Android host halves added: a port the triplet's own list
        # names is upgraded by name as it always was.
        $android_host_names = @($android_host -replace '\[[^\]]+\]','')
        $host_tools         = @(if ($android_host) {
            @(get_host_ports $ANDROID_TRIPLETS $triplet -Tools) -replace '\[[^\]]+\]','' |
                ?{ $_ -in $android_host_names }
        })
        $upgrade_port_names = @($build_port_names | ?{ $_ -notin $host_tools })

        # vcpkg install treats a dependency as satisfied when a package of that
        # name is installed for that triplet: it never compares what is
        # installed against the ports tree. A cross build therefore configures
        # against whatever host copy happens to be there, however stale --
        # qtbase:arm64-android 6.11.2 against a host qtbase left at 6.11.1
        # fails Qt6CoreTools' version check and never configures.
        #
        # The host-dep pass further down cannot fix that: it derives host deps
        # from the target packages that are *installed*, and the port needing
        # the host refresh is exactly the one that fails to install, so it is
        # never in that list and the host copy is never revisited. Refresh the
        # host copies of what we are about to build before building it, and
        # only those already installed for the host triplet, so this stays an
        # upgrade of what the host has and never drags in a new desktop stack.
        if ("$host_t" -and "$host_t" -ne "$triplet") {
            $host_installed = @(vcpkg-list | ?{ $_ -match (":$host_t" + '\s+\d') } | %{ $_ -replace ':.*','' })

            foreach ($port in @($build_port_names | ?{ $_ -in $host_installed })) {
                vcpkg --triplet $host_t --host-triplet $host_t upgrade --no-binarycaching --allow-unsupported --no-dry-run --keep-going $port
            }
        }

        foreach ($port in $build_ports) {
            vcpkg --triplet $triplet --host-triplet $host_t install --no-binarycaching --allow-unsupported --recurse --keep-going $port
        }

        foreach ($port in $upgrade_port_names) {
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

        # For cross-compiling triplets, build the host-tool dependencies for
        # the target architecture's native host triplet (e.g. arm64-windows for
        # an arm64-windows-static target) so they are usable on the target
        # machine.
        #
        # The default toolkit only, for the reason the Android host halves above
        # are: what these provide is build tools that nothing links against, so
        # which toolset built them changes nothing about what they do.
        $is_android = "$triplet" -in $ANDROID_TRIPLETS

        if ($is_android) {
            # Android is never a host. Nothing on the device runs moc or
            # androiddeployqt, so there is no "<target arch>-<host os>" machine
            # to build host tools for -- deriving one the way the branch below
            # does would cross-build a Linux host's tool closure, X11 and all,
            # for an arm64-linux nobody consumes. The host tools an Android
            # build needs are the ones on the machine doing the building, so
            # stay on the host triplet.
            #
            # A host triplet in this run has already built these from its own
            # list. Doing it again here is what covers the run that builds the
            # Android targets and no host triplet at all.
            $target_host_t = "$host_t"
        }
        else {
            # Derive the native host triplet for the target arch: same OS as
            # the build host but the target's own architecture.
            $target_arch   = ($triplet.ToString() -split '-')[0]
            $host_os       = ($host_t -split '-')[1]
            $target_host_t = "$target_arch-$host_os"
        }

        # Nothing to do when that machine is the triplet itself. A plain host
        # triplet stands in for its own machine -- arm64-windows is what an
        # arm64-windows build is hosted on, x64-osx what an x64-osx build is --
        # and its own pass above has just built it from the list that pins its
        # features. Asking the plan about it would match every line of that
        # plan, target and host triplet being one string by then, and hand back
        # the whole target graph as host deps with every [core] pin stripped
        # back to the port's defaults.
        if (-not $packages -and -not $tk -and $host_t -and ("$target_host_t" -ne "$triplet") -and
            ($is_android -or (($triplet -split '-')[0] -ne ($host_t -split '-')[0]))) {
            # The question the host triplets' own lists answer above, asked of
            # this target: what would building it put on that host? vcpkg's plan
            # answers it for the whole graph, so the host deps of ports nobody
            # names are in it -- icu arrives under qtbase and asks for icu on
            # the host to cross-build its data -- which is what the walk over
            # every installed package here used to be for.
            #
            # It also makes what to build and what to publish one list. A
            # consumer restoring the host Qt needs what that Qt was built
            # against -- libb2, md4c, double-conversion, egl, libpq, sqlite3 --
            # or vcpkg-instpkg prunes it as incomplete, prunes the target Qt
            # that names it, and the build compiles Qt from source for both.
            # Those arrived as dependencies of the direct host deps and were
            # never published, since only the direct set was packaged.
            $host_ports      = @(get_host_ports $triplet $target_host_t)
            $host_port_names = @($host_ports -replace '\[[^\]]+\]','')
            # Built and packaged, never upgraded by name, for the reason the
            # Android host halves above are not.
            $th_tools        = @(get_host_ports $triplet $target_host_t -Tools) -replace '\[[^\]]+\]',''

            if ($host_ports) {
                "Building host deps for $target_host_t (cross target: $triplet): $($host_ports -join ', ')"

                setup_build_env $target_host_t

                foreach ($dep in $host_ports) {
                    vcpkg --triplet $target_host_t --host-triplet $host_t install --no-binarycaching --allow-unsupported --recurse --keep-going $dep
                }
                foreach ($dep in @($host_port_names | ?{ $_ -notin $th_tools })) {
                    vcpkg --triplet $target_host_t --host-triplet $host_t upgrade --no-binarycaching --allow-unsupported --no-dry-run --keep-going $dep
                }

                ni -it dir $target_host_t -ea ignore | out-null
                $th_subdir_abs = join-path $stage_dir $target_host_t
                $th_installed  = @(vcpkg-list | ?{ $_ -match (":$target_host_t" + '\s+\d') } | %{ $_ -replace ':.*','' })

                # Same silent gap as the target packing above: a host dep that
                # failed to build just is not in the list.
                foreach ($missing in @($host_port_names | ?{ $_ -notin $th_installed })) {
                    $build_failures += "${missing}:$target_host_t"
                    write-warning "${missing}:$target_host_t did not build, nothing to package"
                }

                $th_installed | ?{ $_ -in $host_port_names } | %{
                    start-threadjob -throttlelimit $throttle -argumentlist $_ -scriptblock {
                        param($_)
                        $pkg       = $_
                        $qualified = "${pkg}:$($using:target_host_t)"
                        import-module $using:binpkg_module
                        set-location $using:th_subdir_abs
                        "Packing $pkg for $($using:target_host_t)..."
                        try {
                            vcpkg-mkpkg $qualified
                        }
                        catch {
                            # Skip a host dep that failed to build, the same as
                            # the target packing above.
                            ri "${pkg}_*.zip" -fo -ea ignore
                            ($using:pack_failures).Add($qualified)
                            write-warning "skipping ${qualified}: packaging failed: $($_.exception.message)"
                        }
                    }
                } | receive-job -wait -autoremovejob

                # The default toolkit's directory is the only one packed into,
                # so that is the only one to upload from.
                if ((-not $added_target_hosts[$target_host_t]) -and ($target_host_t -notin @($build_triplets | %{ "$_" }))) {
                    $added_target_hosts[$target_host_t] = $true
                    $th_obj = [PSCustomObject]@{ Triplet = $target_host_t; Toolkits = @('') }
                    $th_obj | add-member -membertype scriptmethod -name ToString -value { $this.Triplet } -force
                    $extra_triplets += $th_obj
                }
            }
        }
    }
}

teardown_build_env

$build_triplets = @($build_triplets) + @($extra_triplets)

# Packages sftp could not put, filled in by the upload jobs below.
$upload_failures = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

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
        # One sftp session per chunk of packages rather than one per package.
        # Every connection is another chance at the teardown bug handled
        # below, and a triplet has dozens of packages, so a run was doing
        # dozens of connects and disconnects where three will do.
        $upload_throttle = 3
        $zips = @(gci $pkg_subdir_abs -filter '*.zip')
        $chunks = @()
        if ($zips.count) {
            $chunk_size = [math]::max(1, [math]::ceiling($zips.count / $upload_throttle))
            for ($z = 0; $z -lt $zips.count; $z += $chunk_size) {
                $chunks += ,@($zips[$z..([math]::min($z + $chunk_size - 1, $zips.count - 1))])
            }
        }

        $chunks | %{
            start-threadjob -throttlelimit $upload_throttle -argumentlist (,$_) -scriptblock {
                param($chunk)
                $rdir = $using:remote_dir

                # sftp reads this batch a line at a time, so write LF
                # whatever the builder: add-content ends lines the platform's
                # way, and a CR riding along on a put becomes part of the
                # remote file name. set_content_lf lives in the script scope,
                # which a thread job's runspace does not see, so write inline.
                $batch = new-temporaryfile
                $batch_lines = @()
                foreach ($zip in $chunk) {
                    $zip_name = $zip.Name
                    $pkg      = $zip_name -replace '^([^_]+).*', '$1'
                    if ($pkg -in $using:existing_pkgs) {
                        # Leading "-" so sftp keeps going: one glob that
                        # matches nothing would otherwise abandon the rest of
                        # the chunk, which now holds other packages too.
                        $batch_lines += "-rm $rdir/${pkg}_*"
                    }
                    $batch_lines += "put $($zip.FullName) $rdir/$zip_name"
                    $batch_lines += "chmod 664 $rdir/$zip_name"
                }

                [io.file]::WriteAllText($batch.FullName, (($batch_lines -join "`n") + "`n"))

                # On disconnect sftp can report "close - IO is still pending
                # on closed socket" -- a client-side Win32 OpenSSH bug
                # (Win32-OpenSSH#1899), emitted after the transfers, with an
                # exit status of 0. It goes to stderr, and a native command's
                # stderr inside a thread job becomes an error record that
                # receive-job re-raises in the parent, where
                # erroractionpreference stop then killed the whole run --
                # having already uploaded the files. So capture it and judge
                # by the exit status, which is what actually says whether the
                # puts worked.
                $sftp_out  = sftp -b $batch sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/ 2>&1 | out-string
                $sftp_code = $LASTEXITCODE

                remove-item $batch

                if ($sftp_code -ne 0) {
                    foreach ($zip in $chunk) {
                        ($using:upload_failures).Add("$($zip.Name) ($using:remote_dir)")
                    }
                    write-warning "sftp exited $sftp_code uploading to $rdir; these are not published: $(($chunk | % Name) -join ', ')`n$($sftp_out.trim())"
                }
                else {
                    "Uploaded $($chunk.count) package(s) to $rdir."
                }
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

if ($upload_failures.count) {
    "WARNING: failed to upload: $((@($upload_failures) | sort-object -unique) -join ', ')"
}

'INFO: vcpkg packages upgrade successful!'

# vim:sts=4 sw=4 et:
