@echo off
rem clipboard - hand the command line to the resident process when it can answer.
rem
rem client.exe is the compiled client: about 150 ms instead of the roughly 1 s a PowerShell
rem client costs. It is optional. Exit code 100 means it did not answer (no resident, a
rem different tool root, or a command it must not run), and then the script below runs the
rem command itself, exactly as before.
rem
rem The folder goes in without a trailing separator: "%~dp0" ends with one, and a quoted
rem argument ending in a backslash would escape its own closing quote, so the path is taken
rem from the current directory instead. pushd/popd around it, so the command itself still
rem runs in the caller's directory.
if not exist "%~dp0client.exe" goto slow
pushd "%~dp0"
set "CLIENTROOT=%CD%"
popd
"%~dp0client.exe" "%CLIENTROOT%" %*
set "CLIENTRC=%ERRORLEVEL%"
if %CLIENTRC% equ 100 goto slow
exit /b %CLIENTRC%

:slow
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" %*
