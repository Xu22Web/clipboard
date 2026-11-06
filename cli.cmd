@echo off
rem cli - run a command declared in package.ini
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0cli.ps1" %*
exit /b %ERRORLEVEL%
