import-module -force "$psscriptroot/vbam-builder.psm1"
import-module -force "$REPOS_ROOT/vcpkg-binpkg-prototype/vcpkg-binpkg.psm1"

$erroractionpreference = 'stop'
$progresspreference    = 'silentlycontinue'

$stage_dir = "$env:TEMP/vbam-daily-packages"

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

"INFO: vcpkg packages upgrade started on $(date)."

update_vcpkg

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

    git commit -a -m "wxwidgets: update master hash + bump ver" --signoff -S

    git push

    if (-not $?) {
        write-error 'failed to update wxwidgets port in overlay'
    }
}

popd

foreach ($triplet in $TRIPLETS) {
    setup_build_env $triplet

    vcpkg --triplet $triplet install --recurse --keep-going $DEP_PORTS
    vcpkg --triplet $triplet upgrade $DEP_PORT_NAMES --no-dry-run
}

teardown_build_env

# Do full upgrade of all deps, repeat for the MinGW triplets because the toolchain has to be in $env:PATH.
vcpkg upgrade --no-dry-run

foreach ($triplet in (write x86-mingw-static x64-mingw-static)) {
    setup_build_env $triplet
    vcpkg upgrade --no-dry-run
}

teardown_build_env

# Generate binary packages

ri -r -fo  $stage_dir -ea ignore
ni -it dir $stage_dir -ea ignore | out-null

pushd $stage_dir

foreach ($triplet in $TRIPLETS) {
    ni -it dir $triplet -ea ignore | out-null
    pushd $triplet
    vcpkg-list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' } | %{
        "Packing $_ for $triplet..."
        vcpkg-mkpkg "${_}:$triplet"
    }
    popd
}

foreach ($triplet in $TRIPLETS) {
    pushd $triplet
    $existing_pkgs = 'ls' | sftp "sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/vcpkg/$triplet" 2>$null | select -skip 3 | %{ $_ -replace '^([^_]+).*', '$1' }
    gci -n *.zip | %{ 
        $pkg = $_ -replace '^([^_]+).*', '$1'
        if ($pkg -in $existing_pkgs) {
            "rm vcpkg/$triplet/${pkg}*" | sftp sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/
        }
        ("put {0} {1} `n chmod 664 {1}" -f $_,"vcpkg/$triplet/$_") | `
            sftp sftpuser@nightly.visualboyadvance-m.org:nightly.visualboyadvance-m.org/
    }
    popd
}

popd

ri -r -fo $stage_dir

'INFO: vcpkg packages upgrade successful!'

# vim:sts=4 sw=4 et:
