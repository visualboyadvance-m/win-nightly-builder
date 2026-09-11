import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM Nightly Intel'
$runat    = '23:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = task_action -noprofile -script build-nightly.ps1 -log build-nightly-intel.log `
			   -arguments '--triplets x64-windows-static x86-mingw-static'

$principal = new-scheduledtaskprincipal `
    -userid $env:USERNAME `
    -logontype s4u `
    -runlevel highest

register-scheduledtask -force `
    -taskname $taskname `
    -trigger $trigger -action $action `
    -principal $principal `
    -ea stop | out-null

"Task '$taskname' successfully registered to run daily at $runat."
