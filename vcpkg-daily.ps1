import-module -force '/source/repos/vcpkg-binpkg-prototype/vcpkg-binpkg.psm1'

$erroractionpreference = 'stop'

[System.Globalization.CultureInfo]::CurrentCulture = 'en-US'

[Console]::OutputEncoding = [Console]::InputEncoding = `
    $OutputEncoding = new-object System.Text.UTF8Encoding

$triplets        = 'x64-windows-static','x86-windows-static','arm64-windows-static'
$stage_dir       = $env:TEMP + '/vbam-daily-packages'

$env:VCPKG_ROOT  = '/source/repos/vcpkg'
$env:PATH       += ';' + (resolve-path '/program files/git/cmd') + ';' + $env:VCPKG_ROOT

$force_build = if ($args[0] -match '^--?f') { $true} else { $false }

"INFO: vcpkg packages upgrade started on $(date)."

pushd $env:VCPKG_ROOT

git pull --rebase

./bootstrap-vcpkg.bat

./vcpkg.exe upgrade --no-dry-run

popd

# Generate binary packages

ri -r -fo $stage_dir -ea ignore

mkdir $stage_dir | out-null

pushd $stage_dir

foreach($triplet in $triplets) {
	mkdir $triplet -ea ignore | out-null
	pushd $triplet
	vcpkg list | ?{ $_ -match (":$triplet" + '\s+\d') } | %{ $_ -replace ':.*','' } | %{
		vcpkg-mkpkg "${_}:$triplet"
	}
	popd
}

foreach($triplet in $triplets) {
	pushd $triplet
	gci -n | %{
		("put {0} {1} `n chmod 664 {1}" -f $_,"vcpkg/$triplet/$_") `
			| sftp sftpuser@posixsh.org:nightly.vba-m.com/
	}
	popd
}

popd

ri -r -fo $stage_dir

'INFO: vcpkg packages upgrade successful!'