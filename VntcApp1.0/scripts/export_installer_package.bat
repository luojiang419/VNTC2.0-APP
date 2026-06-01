@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_installer_package.ps1"
exit /b %ERRORLEVEL%
