$trigger = new-scheduledtasktrigger -at 23:00 -daily

if (-not (test-path /logs)) { mkdir /logs }

$action  = new-scheduledtaskaction -execute (get-command pwsh).source `
	-argument "-noprofile -executionpolicy remotesigned -command `"& '$(resolve-path $psscriptroot/build-nightly.ps1)' *>> /logs/build-nightly.log`""

register-scheduledtask -force -taskname 'Nightly Buiild (Visual Studio)' `
		       -trigger $trigger -action $action -runlevel highest `
		       -user 'NT AUTHORITY\SYSTEM'
