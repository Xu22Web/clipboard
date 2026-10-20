@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0clipboard.ps1" %*
