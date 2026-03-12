import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'MSYS2 Daily Update'
$runat    = '12:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
    -argument ("-noprofile -executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot msys2-update.ps1)'""" + `
	" *>> $ROOT/logs/msys2-update.log")

$password = (get-credential $env:username).getnetworkcredential().password

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -user $env:username `
    -password $password `
    -runlevel highest `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
