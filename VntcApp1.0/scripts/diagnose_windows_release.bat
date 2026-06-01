@echo off
setlocal

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose_windows_release.ps1" %*

