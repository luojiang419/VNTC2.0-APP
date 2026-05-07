@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows_installer.ps1"
exit /b %ERRORLEVEL%
