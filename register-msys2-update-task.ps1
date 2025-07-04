$erroractionpreference = 'stop'

$taskname = 'MSYS2 Daily Update'
$runat    = '12:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path /logs -ea ignore)) { ni -it dir /logs }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
    -argument ("-noprofile -executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot msys2-update.ps1)'""" + `
	" *>> /logs/msys2-update.log")

$password = (get-credential $env:username).getnetworkcredential().password

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -user $env:username `
    -password $password `
    -runlevel highest `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
