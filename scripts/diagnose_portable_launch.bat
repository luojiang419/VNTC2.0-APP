@echo off
setlocal
PowerShell -ExecutionPolicy Bypass -File "%~dp0diagnose_portable_launch.ps1" %*
