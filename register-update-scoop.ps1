import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM scoop Nightly Upgrade'
$runat    = '10:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute "$env:systemroot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -argument ("-executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot update-scoop.ps1)'""" + `
	" *>> $ROOT/logs/update-scoop.log")

$principal = new-scheduledtaskprincipal `
    -userid $env:USERNAME `
    -logontype interactive `

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -principal $principal `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
