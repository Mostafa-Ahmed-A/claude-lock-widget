@echo off
rem Checks everything the widget depends on and explains what is wrong. Paste the output into bug reports.
setlocal
title Claude Lock Widget - Doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ClaudeLockWidget.ps1" doctor %*
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
