date

'UPDATING Visual Studio'

iwr https://aka.ms/vs/stable/vs_community.exe -outfile "$env:TEMP/vs_community.exe"

& "$env:TEMP/vs_community.exe" update --passive --norestart

start-process powershell '-noprofile', '-windowstyle', 'hidden', `
    '-command', "while (test-path $env:TEMP/vs_community.exe) { sleep 5; ri -fo $env:TEMP/vs_community.exe }"

'DONE!'
