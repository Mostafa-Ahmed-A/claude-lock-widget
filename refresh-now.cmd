@echo off
rem Recomputes your stats and usage and publishes them to the widget immediately.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ClaudeLockWidget.ps1" refresh %*
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
