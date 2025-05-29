$erroractionpreference = 'stop'

$taskname = 'VBAM Hourly Update Repos'

$trigger = new-scheduledtasktrigger -once:$false -at 00:00 -repetitioninterval (new-timespan -hours 1)

if (-not (test-path /logs)) { mkdir /logs }

$action  = new-scheduledtaskaction `
    -execute 'pwsh' `
    -argument ("-executionpolicy remotesigned " + `
	"-command ""& '$(join-path $psscriptroot update-repos.ps1)'""" + `
	" *>> /logs/update-repos.log")

$password = (get-credential $env:username).getnetworkcredential().password

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -user $env:username `
    -password $password `
    -runlevel highest `
    -ea stop | out-null

"Task '$taskname' successfully registered to run hourly."
