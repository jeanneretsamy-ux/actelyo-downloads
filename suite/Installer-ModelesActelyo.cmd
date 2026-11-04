@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer-ModelesActelyo.ps1" %*
set "result=%errorlevel%"
pause
exit /b %result%
