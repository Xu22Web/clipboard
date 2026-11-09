@echo off
rem clipboard - stop the resident, remove the shortcuts, delete data\ and clipboard.ini.
rem cli build copies this file to the package root, which is the folder it expects: run it
rem from there, not from scripts\.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" stop
rem the system copy by full path: a shell on PATH that ships its own timeout (msys, git bash)
rem answers /t with an error, and the wait before the purge would silently not happen. ping is
rem the fallback for a console where timeout refuses to wait with input redirected.
"%SystemRoot%\System32\timeout.exe" /t 2 /nobreak >nul 2>nul
if errorlevel 1 "%SystemRoot%\System32\ping.exe" -n 3 127.0.0.1 >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" uninstall purge
echo.
echo done. data\ and clipboard.ini are gone.
pause
endlocal
