$taskname = 'VBAM Nightly'
$runat    = '23:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path /logs)) { mkdir /logs }

$action  = new-scheduledtaskaction `
    -execute (get-command pwsh).source `
    -argument "-noprofile -executionpolicy remotesigned -command `"& '$(resolve-path $psscriptroot/build-nightly.ps1)' *>> /logs/build-nightly.log`""

$password = (get-credential $env:username).getnetworkcredential().password

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -user $env:username `
    -password $password `
    -runlevel highest | out-null

write "Task '$taskname' successfully registered to run daily at $runat."

# vim:sw=4 et:
