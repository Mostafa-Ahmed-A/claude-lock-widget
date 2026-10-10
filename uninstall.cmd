@echo off
rem Removes the background task, the Claude Code hook + CLAUDE.md note, the widget package and the installed app.
rem Add -Purge to also delete settings, cache and logs.
setlocal
title Claude Lock Widget - Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ClaudeLockWidget.ps1" uninstall %*
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
