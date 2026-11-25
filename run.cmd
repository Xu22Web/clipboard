@echo off
rem run - run a command declared in package.ini (the npm role for this project)
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0run.ps1" %*
exit /b %ERRORLEVEL%
