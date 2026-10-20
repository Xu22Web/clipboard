@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0cb.ps1" %*
