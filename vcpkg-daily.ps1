$root = if ($iswindows) { '' } else { $env:HOME }

import-module -force "$root/source/repos/vcpkg-binpkg-prototype/vcpkg-binpkg.psm1"

$erroractionpreference = 'stop'

[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'

[Console]::OutputEncoding = [Console]::InputEncoding = `
	$OutputEncoding = new-object System.Text.UTF8Encoding

$triplets = if ($iswindows) { 'x64-windows-static','x64-windows','x86-windows-static','x86-windows','arm64-windows-static','arm64-windows' } `
			elseif ($islinux) { 'x64-linux' }

if ($islinux) { $env:TEMP = '/tmp' }

$stage_dir 	= "$env:TEMP/vbam-daily-packages"
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

git pull --rebase

if ($iswindows) {
	./bootstrap-vcpkg.bat
	$vcpkg='./vcpkg.exe'
}
else {
	./bootstrap-vcpkg.sh
	$vcpkg='./vcpkg'
}

&$vcpkg upgrade --no-dry-run

popd

# Generate binary packages

ri -r -fo $stage_dir -ea ignore

mkdir $stage_dir | out-null

pushd $stage_dir

foreach($triplet in $triplets) {
	ni -it dir $triplet -ea ignore | out-null
	pushd $triplet
	vcpkg list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' } | %{
	    vcpkg-mkpkg "${_}:$triplet"
	}
	popd
}

foreach($triplet in $triplets) {
	pushd $triplet
	("rm vcpkg/$triplet/*",(gci -n *.zip | %{ ("put {0} {1} `n chmod 664 {1}" -f $_,"vcpkg/$triplet/$_") ` })) `
	    | sftp sftpuser@posixsh.org:nightly.visualboyadvance-m.org/
	popd
}

popd

ri -r -fo $stage_dir

'INFO: vcpkg packages upgrade successful!'
