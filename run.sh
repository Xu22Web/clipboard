#!/bin/sh
# Git Bash / MSYS wrapper: convert the project path to a Windows path, then hand off to
# PowerShell. The command itself is read from package.ini by run.ps1, which the module layer
# starts the way node starts a script.
here=$(cygpath -w "$(dirname "$0")")
exec powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "$here/packages/module/bin/module.ps1" "$here/run.ps1" "$@"
