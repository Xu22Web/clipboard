@echo off
rem xpm - run a command declared in package.ini
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0xpm.ps1" %*
exit /b %ERRORLEVEL%
