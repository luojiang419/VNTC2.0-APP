@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_portable_package.ps1"
exit /b %ERRORLEVEL%
