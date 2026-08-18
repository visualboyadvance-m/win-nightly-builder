# Run the Pester tests in a clean PowerShell session, so that the profile
# cannot interfere with them, and so that they cannot leave anything behind
# in the session they were started from, the tests replace the environment
# while they run.
#
# They run under whichever PowerShell this is started with:
#
#     pwsh       ./run-tests.ps1
#     powershell ./run-tests.ps1
#
# Select files with -tests and single tests by their full name with
# -filter, e.g.:
#
#     ./run-tests.ps1 -filter '*VCPKG_ROOT*'
#
# Exits with the number of failed tests.

param(
    [string]$tests = "$PSScriptRoot/*.tests.ps1",
    [string]$filter,
    [validateset('none','normal','detailed','diagnostic')]
    [string]$output = 'detailed'
)

$erroractionpreference = 'stop'

$files = @(resolve-path $tests -ea ignore | % path)

if (-not $files) {
    write-error "no test files match '$tests'"
}

if (-not (get-module -listavailable pester | ?{ $_.version -ge [version]'5.0' })) {
    write-error ('Pester 5 or newer is required, install it with: ' +
        'install-module pester -scope currentuser -force')
}

function quote($str) { "'" + ($str -replace "'","''") + "'" }

$command = @(
    '$c = new-pesterconfiguration'
    '$c.run.path = '        + (($files | %{ quote $_ }) -join ',')
    '$c.run.passthru = $true'
    '$c.output.verbosity = ' + (quote $output)
    if ($filter) { '$c.filter.fullname = ' + (quote $filter) }
    'exit (invoke-pester -configuration $c).failedcount'
) -join '; '

# -noprofile so that the profile does not load the Visual Studio environment
# into the session, the tests set up their own.
&(get-process -id $PID).path -noprofile -command $command

exit $lastexitcode
