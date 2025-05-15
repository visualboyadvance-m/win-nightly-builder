$root = if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME }

import-module -force "$root/source/repos/vcpkg-binpkg-prototype/vcpkg-binpkg.psm1"

$erroractionpreference = 'stop'

[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'

[Console]::OutputEncoding = [Console]::InputEncoding = `
    $OutputEncoding = new-object System.Text.UTF8Encoding

$env:PATH               += ';' + (resolve-path '/program files/git/cmd')
$env:VCPKG_ROOT          = "$root/source/repos/vcpkg"
$env:VCPKG_OVERLAY_PORTS = "$root/source/repos/vcpkg-overlay-ports"

. $profile

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

$ports = write pkgconf zlib pthreads sdl3 gettext openal-soft nanosvg sfml ffmpeg faudio

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

git pull --rebase

$temp_dir = "$env:TEMP/wx-port-temp"
ri -r -fo $temp_dir -ea ignore
ni -it dir $temp_dir -ea ignore | out-null

pushd $temp_dir

curl -LO https://github.com/wxWidgets/wxWidgets/archive/master.tar.gz

$new_wx_hash = (get-filehash -a sha512 master.tar.gz).hash.tolower()

popd

ri -r -fo $temp_dir

$current_wx_ver = vcpkg list | sls 'wxwidgets:x64-windows-static\s+(\S+)' | %{ if ($_) { $_.matches.groups[1].value } else { 0 } }
$port_wx_ver    = (@(gc wxwidgets/vcpkg.json) | sls '"version": "([^"]+)"').matches.groups[1].value

$hash_changed   = -not ((gc wxwidgets/portfile.cmake) -match $new_wx_hash)

if (($current_wx_ver -ne $port_wx_ver) -or $hash_changed) {
    if ($hash_changed) {
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
    }

    foreach($triplet in $triplets) {
        &$vcpkg --triplet $triplet upgrade wxwidgets --no-dry-run
        &$vcpkg --triplet $triplet install wxwidgets
    }
    git commit -a -m "wxwidgets: update master hash + bump ver" --signoff -S

    git push -f
}

popd

foreach($triplet in $triplets) {
    &$vcpkg --triplet $triplet upgrade @($ports -replace '\[[^\]]+\]','') --no-dry-run
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
