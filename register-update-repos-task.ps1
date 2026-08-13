import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM Hourly Update Repos'

$trigger = new-scheduledtasktrigger -once:$false -at 00:00 -repetitioninterval (new-timespan -hours 1)

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute "$env:systemroot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -argument ("-executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot update-repos.ps1)'""" + `
	" *>> $ROOT/logs/update-repos.log")

$principal = new-scheduledtaskprincipal `
    -userid $env:USERNAME `
    -logontype s4u `
    -runlevel highest

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -principal $principal `
    -ea stop | out-null

"Task '$taskname' successfully registered to run hourly."
