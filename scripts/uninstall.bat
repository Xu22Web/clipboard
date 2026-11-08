@echo off
rem clipboard - stop the resident, remove the shortcuts, delete data\ and clipboard.ini.
rem cli build copies this file to the package root, which is the folder it expects: run it
rem from there, not from scripts\.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" stop
timeout /t 2 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" uninstall purge
echo.
echo done. data\ and clipboard.ini are gone.
pause
endlocal
