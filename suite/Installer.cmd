@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer-ActelyoSuite.ps1" -Mode Install -StartupOnly %*
set "result=%errorlevel%"
if not "%result%"=="0" goto finished
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer-ModelesActelyo.ps1"
set "result=%errorlevel%"
:finished
pause
exit /b %result%
