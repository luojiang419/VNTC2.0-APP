@echo off
setlocal

set "PROJECT_DIR=%~dp0.."
set "FLUTTER_BIN=D:\APPdata\flutter\bin\flutter.bat"
set "RUST_BIN=%USERPROFILE%\.cargo\bin"

if not exist "%FLUTTER_BIN%" (
  echo [ERROR] Flutter not found: %FLUTTER_BIN%
  exit /b 1
)

if exist "%RUST_BIN%\cargo.exe" (
  set "PATH=%RUST_BIN%;%PATH%"
)

where cargo >nul 2>nul
if errorlevel 1 (
  echo [ERROR] cargo not found in PATH. Please install Rust stable toolchain first.
  exit /b 1
)

cd /d "%PROJECT_DIR%"
set "CARGO_NET_GIT_FETCH_WITH_CLI=true"

call "%FLUTTER_BIN%" config --enable-windows-desktop
if errorlevel 1 exit /b 1

call "%FLUTTER_BIN%" pub get
if errorlevel 1 exit /b 1

call "%FLUTTER_BIN%" run -d windows
