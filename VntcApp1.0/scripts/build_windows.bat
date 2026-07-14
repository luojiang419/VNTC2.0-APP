@echo off
setlocal

set "PROJECT_DIR=%~dp0.."
set "FLUTTER_BIN=D:\APPdata\flutter\bin\flutter.bat"
set "RUST_BIN=%USERPROFILE%\.cargo\bin"
set "VERSION_FILE=%PROJECT_DIR%\scripts\build_version.txt"
set "RELEASE_DIR=%PROJECT_DIR%\build\windows\x64\runner\Release"
set "DIST_DIR=%PROJECT_DIR%\dist"
set "OUTPUT_DIR=%PROJECT_DIR%\output"
set "LAUNCHER_EXE=%PROJECT_DIR%\windows_launcher\vnt_app.exe"

if not exist "%FLUTTER_BIN%" (
  echo [ERROR] Flutter not found: %FLUTTER_BIN%
  exit /b 1
)

if exist "%RUST_BIN%\cargo.exe" (
  set "PATH=%RUST_BIN%;%PATH%"
)

if "%VNT_BUILD_VERSION%"=="" (
  if not exist "%VERSION_FILE%" (
    echo [ERROR] Build version file missing: %VERSION_FILE%
    exit /b 1
  )
  set /p VNT_BUILD_VERSION=<"%VERSION_FILE%"
)

for /f "tokens=* delims= " %%I in ("%VNT_BUILD_VERSION%") do set "VNT_BUILD_VERSION=%%I"
set "VNT_BUILD_DISPLAY_VERSION=v%VNT_BUILD_VERSION%"
set "VNT_BUILD_NAME=%VNT_BUILD_VERSION%.0"
for /f "tokens=1-4 delims=." %%A in ("%VNT_BUILD_VERSION%") do if not "%%C"=="" set "VNT_BUILD_NAME=%VNT_BUILD_VERSION%"
set "VNT_BUILD_PRODUCT_NAME=VNTC APP2.0"
set "VNT_BUILD_TITLE=%VNT_BUILD_PRODUCT_NAME% %VNT_BUILD_DISPLAY_VERSION%"

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

call "%FLUTTER_BIN%" build windows --release --build-name %VNT_BUILD_NAME% "--dart-define=APP_BASE_TITLE=VNTC APP2.0" "--dart-define=APP_BUILD_VERSION=%VNT_BUILD_VERSION%" "--dart-define=APP_DISPLAY_VERSION=%VNT_BUILD_DISPLAY_VERSION%" "--dart-define=APP_PRODUCT_NAME=%VNT_BUILD_PRODUCT_NAME%" "--dart-define=APP_WINDOW_TITLE=%VNT_BUILD_TITLE%"
if errorlevel 1 exit /b 1

if not exist "%RELEASE_DIR%" (
  echo [ERROR] Release directory missing after build: %RELEASE_DIR%
  exit /b 1
)

if not exist "%RELEASE_DIR%\native_assets.json" (
  >"%RELEASE_DIR%\native_assets.json" echo {"format-version":[1,0,0],"native-assets":{}}
)

PowerShell -ExecutionPolicy Bypass -File "%PROJECT_DIR%\scripts\prepare_sqlite_runtime.ps1" -ProjectDir "%PROJECT_DIR%" -TargetDir "%RELEASE_DIR%"
if errorlevel 1 exit /b 1

if not exist "%RELEASE_DIR%\dlls\amd64\wintun.dll" (
  echo [ERROR] Wintun runtime missing: %RELEASE_DIR%\dlls\amd64\wintun.dll
  exit /b 1
)

copy /Y "%RELEASE_DIR%\dlls\amd64\wintun.dll" "%RELEASE_DIR%\wintun.dll" >nul
if errorlevel 1 exit /b 1

copy /Y "%PROJECT_DIR%\scripts\diagnose_portable_launch.ps1" "%RELEASE_DIR%\diagnose_portable_launch.ps1" >nul
if errorlevel 1 exit /b 1
copy /Y "%PROJECT_DIR%\scripts\diagnose_portable_launch.bat" "%RELEASE_DIR%\diagnose_portable_launch.bat" >nul
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
  copy /Y "%DIST_DIR%\vnt_app.exe" "%DIST_DIR%\vnt_app_runner.exe" >nul
  if errorlevel 1 exit /b 1
  copy /Y "%LAUNCHER_EXE%" "%DIST_DIR%\vnt_app.exe" >nul
  if errorlevel 1 exit /b 1

  copy /Y "%OUTPUT_DIR%\vnt_app.exe" "%OUTPUT_DIR%\vnt_app_runner.exe" >nul
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

exit /b 0
