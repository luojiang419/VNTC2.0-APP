@echo off
setlocal

set "PROJECT_DIR=%~dp0.."
set "FLUTTER_BIN="
if exist "G:\data\flutter\bin\flutter.bat" set "FLUTTER_BIN=G:\data\flutter\bin\flutter.bat"
if not defined FLUTTER_BIN if exist "D:\APPdata\flutter\bin\flutter.bat" set "FLUTTER_BIN=D:\APPdata\flutter\bin\flutter.bat"
if not defined FLUTTER_BIN for /f "delims=" %%I in ('where flutter.bat 2^>nul') do if not defined FLUTTER_BIN set "FLUTTER_BIN=%%I"
if not defined FLUTTER_BIN for /f "delims=" %%I in ('where flutter 2^>nul') do if not defined FLUTTER_BIN set "FLUTTER_BIN=%%I"
set "RUST_BIN=%USERPROFILE%\.cargo\bin"
set "RELEASE_DIR=%PROJECT_DIR%\build\windows\x64\runner\Release"
set "DIST_DIR=%PROJECT_DIR%\dist"
set "OUTPUT_DIR=%PROJECT_DIR%\output"
set "LAUNCHER_EXE=%PROJECT_DIR%\windows_launcher\vnt_app.exe"
set "RUSTDESK_RUNTIME_DIR=%PROJECT_DIR%\third_party\rustdesk\windows\runtime"
if not defined PUB_HOSTED_URL set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
if not defined FLUTTER_STORAGE_BASE_URL set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

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

PowerShell -ExecutionPolicy Bypass -File "%PROJECT_DIR%\scripts\prepare_rustdesk_runtime.ps1"
if errorlevel 1 exit /b 1

call "%FLUTTER_BIN%" build windows --release
if errorlevel 1 exit /b 1

call "%PROJECT_DIR%\scripts\build_windows_launcher.bat"
if errorlevel 1 exit /b 1

if not exist "%RUSTDESK_RUNTIME_DIR%\rustdesk.exe" (
  echo [ERROR] RustDesk runtime not prepared: %RUSTDESK_RUNTIME_DIR%
  exit /b 1
)
if not exist "%RUSTDESK_RUNTIME_DIR%\rustdesk_qs.exe" (
  copy /Y "%RUSTDESK_RUNTIME_DIR%\rustdesk.exe" "%RUSTDESK_RUNTIME_DIR%\rustdesk_qs.exe" >nul
  if errorlevel 1 exit /b 1
)

robocopy "%RUSTDESK_RUNTIME_DIR%" "%RELEASE_DIR%\rustdesk_runtime" /MIR >nul
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%

copy /Y "%PROJECT_DIR%\scripts\diagnose_portable_launch.ps1" "%RELEASE_DIR%\diagnose_portable_launch.ps1" >nul
if errorlevel 1 exit /b 1
copy /Y "%PROJECT_DIR%\scripts\diagnose_portable_launch.bat" "%RELEASE_DIR%\diagnose_portable_launch.bat" >nul
if errorlevel 1 exit /b 1

PowerShell -ExecutionPolicy Bypass -File "%PROJECT_DIR%\scripts\copy_windows_runtime_deps.ps1" ^
  -TargetDirs "%RELEASE_DIR%,%RELEASE_DIR%\rustdesk_runtime"
if errorlevel 1 exit /b 1

if not exist "%DIST_DIR%" (
  mkdir "%DIST_DIR%"
  if errorlevel 1 exit /b 1
)

robocopy "%RELEASE_DIR%" "%DIST_DIR%" /MIR >nul
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%

if not exist "%OUTPUT_DIR%" (
  mkdir "%OUTPUT_DIR%"
  if errorlevel 1 exit /b 1
)

robocopy "%RELEASE_DIR%" "%OUTPUT_DIR%" /MIR >nul
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%

if exist "%LAUNCHER_EXE%" (
  copy /Y "%RELEASE_DIR%\vnt_app.exe" "%DIST_DIR%\vnt_app_runner.exe" >nul
  if errorlevel 1 exit /b 1
  copy /Y "%LAUNCHER_EXE%" "%DIST_DIR%\vnt_app.exe" >nul
  if errorlevel 1 exit /b 1

  copy /Y "%RELEASE_DIR%\vnt_app.exe" "%OUTPUT_DIR%\vnt_app_runner.exe" >nul
  if errorlevel 1 exit /b 1
  copy /Y "%LAUNCHER_EXE%" "%OUTPUT_DIR%\vnt_app.exe" >nul
  if errorlevel 1 exit /b 1
)

PowerShell -ExecutionPolicy Bypass -File "%PROJECT_DIR%\scripts\sanitize_distribution_config.ps1" ^
  -ConfigPaths "%RELEASE_DIR%\config\config.json,%DIST_DIR%\config\config.json,%OUTPUT_DIR%\config\config.json"
if errorlevel 1 exit /b 1

echo [OK] Build finished: %RELEASE_DIR%
echo [OK] Dist synced: %DIST_DIR%
echo [OK] Output synced: %OUTPUT_DIR%
