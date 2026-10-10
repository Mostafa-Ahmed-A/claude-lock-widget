@echo off
rem Claude Lock Widget - installer. Double-click this file.
rem Installs the app + background task, optionally the Claude Code hook, and the lock screen widget package.
setlocal
title Claude Lock Widget - Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ClaudeLockWidget.ps1" install %*
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
