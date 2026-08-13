import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'MSYS2 Daily Update'
$runat    = '12:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute "$env:systemroot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -argument ("-noprofile -executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot msys2-update.ps1)'""" + `
	" *>> $ROOT/logs/msys2-update.log")

$principal = new-scheduledtaskprincipal `
    -userid $env:USERNAME `
    -logontype s4u `
    -runlevel highest

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -principal $principal `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
