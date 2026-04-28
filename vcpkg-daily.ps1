import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$stage_dir = "$env:TEMP/vbam-daily-packages"

$packages      = $null
$skip_packages = @()
$filtered_args = @()
for ($i = 0; $i -lt $args.count; $i++) {
    if     ($args[$i] -match '^--?packages?=(.+)')                             { $packages      = $matches[1] -split ',' }
    elseif ($args[$i] -match '^--?packages?$'      -and $i+1 -lt $args.count) { $packages      = $args[++$i] -split ',' }
    elseif ($args[$i] -match '^--?skip-?packages?=(.+)')                        { $skip_packages = $matches[1] -split ',' }
    elseif ($args[$i] -match '^--?skip-?packages?$' -and $i+1 -lt $args.count) { $skip_packages = $args[++$i] -split ',' }
    else   { $filtered_args += $args[$i] }
}

$force_build = if ($filtered_args[0] -match '^--?f') { $true} else { $false }

$build_triplets = get-triplets @filtered_args

if ($packages) {
    $unknown = $packages | ?{ $_ -notin $DEP_PORT_NAMES }
    if ($unknown) { write-error "Unknown package(s): $($unknown -join ', ')" -ea stop }
    $build_ports = $DEP_PORTS | ?{ ($_ -replace '\[[^\]]+\]','') -in $packages }
} else {
    $build_ports = $DEP_PORTS
}
if ($skip_packages) {
    $unknown = $skip_packages | ?{ $_ -notin $DEP_PORT_NAMES }
    if ($unknown) { write-error "Unknown skip package(s): $($unknown -join ', ')" -ea stop }
    $build_ports = $build_ports | ?{ ($_ -replace '\[[^\]]+\]','') -notin $skip_packages }
}
$build_port_names = $build_ports -replace '\[[^\]]+\]',''

"INFO: vcpkg packages upgrade started on $(date)."

if (-not $islinux -and 'wxwidgets' -in $build_port_names) {
    $temp_dir = "$env:TEMP/wx-port-temp"

    ni -it dir $temp_dir -ea ignore | out-null

    pushd $temp_dir

    curl -LO https://github.com/wxWidgets/wxWidgets/archive/master.tar.gz

    $new_wx_hash = (get-filehash -a sha512 master.tar.gz).hash.tolower()

    popd

    ri -r -fo $temp_dir

    pushd $env:VCPKG_OVERLAY_PORTS

    if (-not ((gc wxwidgets/portfile.cmake) -match $new_wx_hash)) {
        @(gc wxwidgets/portfile.cmake) | %{ $_ -replace 'SHA512 .*',"SHA512 $new_wx_hash" } | set-content wxwidgets/portfile.cmake

        $wx_master_ver = (
            iwr https://raw.githubusercontent.com/wxWidgets/wxWidgets/refs/heads/master/include/wx/version.h | % content |
            sls '.*wxVERSION_STRING\D+([\d.]+).*' | select -first 1
        ).matches.groups[1].value

        @(gc .\wxwidgets\vcpkg.json) | %{
            $(if ($_ -match '^(  "version": ")([^-]+)-(\d+)(".*)') {
                $matches.1 + $wx_master_ver + '-' +
                $(if ($matches.2 -ne $wx_master_ver) { 1 } `
                  else { [convert]::toint32($matches.3) + 1 }) +
                $matches.4 } `
            else { $_ }) } | set-content wxwidgets/vcpkg.json

        git pull --rebase
        git commit -a -m "wxwidgets: update master hash + bump ver" --signoff
        git pull --rebase

        git push

        if (-not $?) {
            write-error 'failed to update wxwidgets port in overlay'
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

foreach ($triplet in $build_triplets) {
    foreach ($tk in $triplet.toolkits) {
        setup_build_env $triplet $tk

        $binpkg_module ??= (get-module vcpkg-binpkg).path
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
        vcpkg-list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' } | ?{ -not $packages -or $_ -in $build_port_names } | ForEach-Object -ThrottleLimit $throttle -Parallel {
            import-module $using:binpkg_module
            set-location $using:pkg_subdir_abs
            "Packing $_ for $($using:triplet_s)$(if ($using:tk) { " ($($using:tk))" })..."
            vcpkg-mkpkg "${_}:$($using:triplet_s)"
        }

        # For cross-compiling triplets, build host-tool dependencies for the
        # target architecture's native host triplet (e.g. arm64-windows for an
        # arm64-windows-static target) so they are usable on the target machine.
        if (-not $packages -and $host_t -and ($triplet -split '-')[0] -ne ($host_t -split '-')[0]) {
            # Derive the native host triplet for the target arch: same OS as
            # the build host but the target's own architecture.
            $target_arch   = ($triplet.ToString() -split '-')[0]
            $host_os       = ($host_t -split '-')[1]
            $target_host_t = "$target_arch-$host_os"

            $installed = vcpkg-list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' } | ?{ $_ -in $build_port_names }
            if ($installed) {
                $qualified = @($installed | %{ "${_}:$triplet" })
                $host_deps = @(vcpkg-listhostdeps @qualified) | ?{ $_ } | select-object -unique
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

                        $th_subdir = if ($th_tk) { "$target_host_t/$th_tk" } else { $target_host_t }
                        ni -it dir $th_subdir -ea ignore | out-null
                        $th_subdir_abs = join-path $stage_dir $th_subdir
                        vcpkg-list | ?{ $_ -match (":$target_host_t" + '\s+\d') } | %{ $_ -replace ':.*','' } | ForEach-Object -ThrottleLimit $throttle -Parallel {
                            import-module $using:binpkg_module
                            set-location $using:th_subdir_abs
                            "Packing $_ for $($using:target_host_t)$(if ($using:th_tk) { " ($($using:th_tk))" })..."
                            vcpkg-mkpkg "${_}:$($using:target_host_t)"
                        }
                    }

                    if (-not $added_target_hosts[$target_host_t]) {
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
        $existing_pkgs = 'ls' | sftp "sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/$remote_dir" 2>$null | select -skip 3 | %{ $_ -replace '^([^_]+).*', '$1' }
        gci $pkg_subdir_abs -filter '*.zip' | ForEach-Object -ThrottleLimit 3 -Parallel {
            $zip_name = $_.Name
            $zip_full = $_.FullName
            $pkg      = $zip_name -replace '^([^_]+).*', '$1'
            $rdir     = $using:remote_dir

            $batch = new-temporaryfile
            if ($pkg -in $using:existing_pkgs) {
                add-content $batch "rm $rdir/${pkg}_*"
            }
            add-content $batch "put $zip_full $rdir/$zip_name"
            add-content $batch "chmod 664 $rdir/$zip_name"

            sftp -b $batch sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/
            remove-item $batch
        }
    }
}

popd

ri -r -fo $stage_dir

'INFO: vcpkg packages upgrade successful!'

# vim:sts=4 sw=4 et:
