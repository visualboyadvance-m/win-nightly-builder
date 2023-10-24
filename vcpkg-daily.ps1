[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'

[Console]::OutputEncoding = [Console]::InputEncoding = `
    $OutputEncoding = new-object System.Text.UTF8Encoding

$env:PATH          += ';' + (resolve-path '/program files/git/cmd')
$env:VCPKG_ROOT     = '/source/repos/vcpkg'

$stage_dir = '/windows/temp/vbam-daily-packages'

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

"INFO: vcpkg upgrade started on $(date)."

pushd $env:VCPKG_ROOT

git pull --rebase

./bootstrap-vcpkg.bat

./vcpkg.exe upgrade --no-dry-run

popd

#
#ri -r -fo $stage_dir -ea ignore
#
#mkdir $stage_dir | out-null
#
#pushd $stage_dir
#
#gci -n | %{ ("put {0}`nchmod 664 {0}" -f $_) | sftp sftpuser@posixsh.org:nightly.vba-m.com/ }
#
#popd
#
#ri -r -fo $stage_dir

'INFO: vcpkg upgrade successful!'