import-module -force "$psscriptroot/vbam-builder.psm1"

$erroractionpreference = 'stop'

$taskname = 'VBAM vcpkg Daily Upgrade'

# Early enough to be finished before the nightly starts at 23:00, which at
# 21:00 it generally was not: over 39 recorded runs the median was 1.6 h but
# the 90th percentile was 9.6 h and the longest 17 h, so a two hour run-up fit
# about half of them. This fits 36 of the 39.
#
# 13:00 rather than earlier because the morning is taken -- Visual Studio at
# 08:00, winget at 09:00, scoop at 10:00, MSYS2 at 12:00 -- and the
# x86-mingw-static builds take their compiler out of C:/msys64/mingw32, so
# starting before that update has finished would change a toolchain under a
# build.
#
# It is not a fix on its own and is not meant to be: nothing clears a 17 hour
# run before 23:00, and build-nightly.ps1 waits on the vcpkg trees' locks for
# the days when this one is still going. What moving it does is make that wait
# the exception rather than most nights.
$runat    = '13:00'

$trigger = new-scheduledtasktrigger -at $runat -daily

if (-not (test-path $ROOT/logs)) { ni -it dir $ROOT/logs > $null }

$action  = task_action -script vcpkg-daily.ps1 -log vcpkg-daily.log

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
