# tools\utils\console.ps1 - the two lines every tool prints the same way.
#
# A step is "[..] what is happening", a failure is "[x] what went wrong" followed by exit 1.
# The prefix is what makes the output greppable, and the tools that read cli.ini report their
# settings and their problems through these two instead of each spelling the prefix itself.

function Write-Step([string]$text) { Write-Host ('[..] ' + $text) }
function Fail([string]$text) { Write-Host ('[x] ' + $text); exit 1 }
