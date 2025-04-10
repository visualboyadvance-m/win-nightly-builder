$root = if ($iswindows) { '' } else { $env:HOME }

import-module -force "$root/source/repos/vcpkg-binpkg-prototype/vcpkg-binpkg.psm1"

$erroractionpreference = 'stop'

[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'

[Console]::OutputEncoding = [Console]::InputEncoding = `
    $OutputEncoding = new-object System.Text.UTF8Encoding

$triplets = if ($iswindows) { 'x64-windows-static','x64-windows','x86-windows-static','x86-windows','arm64-windows-static','arm64-windows' } `
            elseif ($islinux) { 'x64-linux' }

if ($islinux) { $env:TEMP = '/tmp' }

$stage_dir      = "$env:TEMP/vbam-daily-packages"
$env:VCPKG_ROOT = "$root/source/repos/vcpkg"

if ($iswindows) {
    $env:PATH = $env:VCPKG_ROOT + ';' + (resolve-path '/program files/git/cmd') + ';' + $env:PATH
}
else {
    $env:PATH = $env:VCPKG_ROOT + ':' + $env:PATH
}

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

"INFO: vcpkg packages upgrade started on $(date)."

pushd $env:VCPKG_ROOT

if ($iswindows) {
    .\bootstrap-vcpkg.bat
    $vcpkg=$env:VCPKG_ROOT + '\vcpkg.exe'
}
else {
    ./bootstrap-vcpkg.sh
    $vcpkg=$env:VCPKG_ROOT + '/vcpkg'
}

pushd $env:VCPKG_OVERLAY_PORTS

$temp_dir = "$env:TEMP/wx-port-temp"
ri -r -fo $temp_dir -ea ignore
ni -it dir $temp_dir -ea ignore | out-null

pushd $temp_dir

curl -LO https://github.com/wxWidgets/wxWidgets/archive/master.tar.gz

$new_wx_hash = (get-filehash -a sha512 master.tar.gz).hash.tolower()

popd

if (-not ((gc wxwidgets/portfile.cmake) -match $new_wx_hash)) {
    @(gc wxwidgets/portfile.cmake) | %{ $_ -replace 'SHA512 .*',"SHA512 $new_wx_hash" } | set-content wxwidgets/portfile.cmake

    @(gc .\wxwidgets\vcpkg.json) | %{
        if ($_ -match '^(  "version": ")([^-]+)-(\d+)(".*)')
            { $matches.1 + $matches.2 + '-' + ([convert]::toint32($matches.3) + 1) + $matches.4 }
        else { $_ } } | set-content wxwidgets/vcpkg.json

    foreach($triplet in $triplets) {
        &$vcpkg --triplet $triplet install wxwidgets
    }
    git commit -a -m "wxwidgets: update master hash + bump ver" --signoff -S

    git push -f
}

ri -r -fo $temp_dir

popd

foreach($triplet in $triplets) {
    &$vcpkg --triplet $triplet upgrade --no-dry-run
}

popd

# Generate binary packages

ri -r -fo $stage_dir -ea ignore

ni -it dir $stage_dir -ea ignore | out-null

pushd $stage_dir

foreach($triplet in $triplets) {
    ni -it dir $triplet -ea ignore | out-null
    pushd $triplet
    vcpkg list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' } | %{
        "Packing $_ for $triplet..."
        vcpkg-mkpkg "${_}:$triplet"
    }
    popd
}

foreach($triplet in $triplets) {
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
