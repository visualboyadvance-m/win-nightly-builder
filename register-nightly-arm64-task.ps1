import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM Nightly'
$runat    = '23:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
    -argument ("-noprofile -executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot build-nightly.ps1)' --triplets arm64-windows-static""" + `
	" *>> $ROOT/logs/build-nightly.log")

$password = (get-credential $env:username).getnetworkcredential().password

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -user $env:username `
    -password $password `
    -runlevel highest `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
