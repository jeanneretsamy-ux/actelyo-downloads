@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer-ActelyoSuite.ps1" -Mode Verify -StartupOnly %*
set "result=%errorlevel%"
pause
exit /b %result%
