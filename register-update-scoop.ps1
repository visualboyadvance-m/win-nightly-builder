import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM winget Nightly Upgrade'
$runat    = '10:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
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
