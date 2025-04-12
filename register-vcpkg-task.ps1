$erroractionpreference = 'stop'

$taskname = 'VBAM vcpkg Daily Upgrade'
$runat    = '21:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path /logs)) { mkdir /logs }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
    -argument ("-executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot vcpkg-daily.ps1)'""" + `
	" *>> /logs/vcpkg-daily.log")

$password = (get-credential $env:username).getnetworkcredential().password

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -user $env:username `
    -password $password `
    -runlevel highest `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
