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

# Under Windows PowerShell -- which is what the scheduled task runs -- a native
# command's redirected stderr becomes an error record, and the erroractionpreference
# of stop above turns the first one of those into a terminating error. git reports
# everything it does on stderr, down to "From github.com", so the first fetch would
# take the whole run down. Relax the preference for the call, scoped to this
# function, and hand back what git said as plain text.
function git_out {
    $erroractionpreference = 'continue'

    @(& git @args 2>&1 | %{ "$_" })
}

echo vcpkg vcpkg-binpkg-prototype vcpkg-overlay win-nightly-builder windows-dev-guide | %{
    pushd "$root/source/repos/$_"

    # Last line, so a stray warning from git cannot be mistaken for the branch.
    $branch = @(git_out rev-parse --abbrev-ref HEAD)[-1]

    if ($branch -ne 'master') {
        write-warning "Skipping '$_', on branch '$branch' rather than 'master'."
    }
    elseif (git_out status --porcelain) {
        write-warning "Skipping '$_', working tree is not clean."
    }
    else {
        git_out fetch --all --prune
        git_out pull --rebase

        if ($lastexitcode -ne 0) {
            write-warning "Updating '$_' failed, git pull exited with $lastexitcode."
        }
    }

    popd
}
