import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM Visual Studio Nightly Upgrade'
$runat    = '08:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
    -argument ("-executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot update-vs.ps1)'""" + `
	" *>> $ROOT/logs/update-vs.log")

$principal = new-scheduledtaskprincipal `
    -userid $env:USERNAME `
    -logontype interactive `
    -runlevel highest

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -principal $principal `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
