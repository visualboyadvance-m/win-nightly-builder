$erroractionpreference = 'stop'

# Windows PowerShell does not have OS automatic variables.
if (-not (test-path variable:global:iswindows)) {
    $global:IsWindows = $false
    $global:IsLinux   = $false
    $global:IsMacOS   = $false

    if (get-command get-cimsession -ea ignore) {
        $global:IsWindows = $true
    }
    elseif (test-path /System/Library/Extensions) {
        $global:IsMacOS   = $true
    }
    else {
        $global:IsLinux   = $true
    }
}

if ($iswindows) {
    $env:PATH += ';' + (resolve-path '/program files/git/cmd')
}

$root = if ($iswindows) { if ((hostname) -eq 'win_builder') { '' } else { $env:USERPROFILE } } else { $env:HOME }

echo vcpkg vcpkg-binpkg-prototype vcpkg-overlay win-nightly-builder windows-dev-guide | %{
    pushd "$root/source/repos/$_"

    $branch = git rev-parse --abbrev-ref HEAD

    if ($branch -ne 'master') {
        write-warning "Skipping '$_', on branch '$branch' rather than 'master'."
    }
    elseif (git status --porcelain) {
        write-warning "Skipping '$_', working tree is not clean."
    }
    else {
        git fetch --all --prune
        git pull --rebase

        if ($LASTEXITCODE -ne 0) {
            write-warning "Updating '$_' failed, git pull exited with $LASTEXITCODE."
        }
    }

    popd
}
