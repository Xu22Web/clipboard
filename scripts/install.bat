@echo off
rem clipboard - write a commented clipboard.ini, upgrade an older history, then create the two
rem shortcuts. cli build copies this file to the package root, which is the folder it expects:
rem run it from there, not from scripts\.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" config init
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" migrate
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" install
echo.
echo done. the hotkey is the Hotkey= line in clipboard.ini.
pause
endlocal
