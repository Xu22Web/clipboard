@echo off
rem run - run a command declared in package.ini (the npm role for this project)
rem The command file is started by the module layer, the way npm starts node: one process per
rem command line, with the import statements live.
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0packages\module\bin\module.ps1" "%~dp0run.ps1" %*
exit /b %ERRORLEVEL%
