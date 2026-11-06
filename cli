#!/bin/sh
# Git Bash / MSYS wrapper: convert the project path to a Windows path, then hand off to
# PowerShell. The command itself is read from package.ini by cli.ps1.
exec powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "$(cygpath -w "$(dirname "$0")")/cli.ps1" "$@"
