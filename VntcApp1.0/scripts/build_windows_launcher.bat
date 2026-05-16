@echo off
PowerShell -ExecutionPolicy Bypass -File "%~dp0build_windows_launcher.ps1"
exit /b %ERRORLEVEL%
