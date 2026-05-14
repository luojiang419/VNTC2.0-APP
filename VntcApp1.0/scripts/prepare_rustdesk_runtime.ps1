param(
    [string]$Version = "1.4.6"
)

$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $projectDir "third_party\rustdesk\windows\runtime"
$customFile = Join-Path $projectDir "third_party\rustdesk\windows\custom.txt"
$cacheDir = Join-Path $env:TEMP "vnt_rustdesk_cache"
$downloadPath = Join-Path $cacheDir "rustdesk-$Version-x86_64.exe"
$extractedDir = Join-Path $env:LOCALAPPDATA "rustdesk"

if (!(Test-Path -LiteralPath $customFile)) {
    throw "Missing custom RustDesk config: $customFile"
}

if (!(Test-Path -LiteralPath $cacheDir)) {
    New-Item -ItemType Directory -Path $cacheDir | Out-Null
}

if (!(Test-Path -LiteralPath $downloadPath)) {
    $url = "https://github.com/rustdesk/rustdesk/releases/download/$Version/rustdesk-$Version-x86_64.exe"
    Write-Host "[RustDesk] Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $downloadPath
}

Write-Host "[RustDesk] Expanding runtime via bootstrap executable"
& $downloadPath --version | Out-Null

if (!(Test-Path -LiteralPath (Join-Path $extractedDir "rustdesk.exe"))) {
    throw "RustDesk runtime was not extracted to $extractedDir"
}

if (Test-Path -LiteralPath $runtimeRoot) {
    Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

Write-Host "[RustDesk] Copying runtime to $runtimeRoot"
Copy-Item -Path (Join-Path $extractedDir "*") -Destination $runtimeRoot -Recurse -Force
Copy-Item -LiteralPath $customFile -Destination (Join-Path $runtimeRoot "custom.txt") -Force
Set-Content -LiteralPath (Join-Path $runtimeRoot "runtime-version.txt") -Value $Version -NoNewline

Write-Host "[RustDesk] Runtime ready: $runtimeRoot"
