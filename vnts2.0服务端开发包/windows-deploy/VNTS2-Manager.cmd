@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0vnts2-manager.ps1"
endlocal
