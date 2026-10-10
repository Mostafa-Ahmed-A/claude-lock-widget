@echo off
rem Renders the widget tile from your real data and opens it. Does NOT install or change anything.
rem Add -Demo to use sample data instead.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ClaudeLockWidget.ps1" preview %*
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" pause
exit /b %EXITCODE%
