[CmdletBinding()]
param([string]$Version = '4.5')

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$dockerfile = Join-Path $projectDir 'linux_webui\docker\Dockerfile.native-debian12'
$releaseRoot = Join-Path $projectDir 'release\linux_webui'
$packageBase = "VNTC_Linux_WebUI_${Version}_Debian12_x86_64"
$stageDir = Join-Path $releaseRoot $packageBase
$archivePath = Join-Path $releaseRoot "$packageBase.tar.gz"
$hashPath = "$archivePath.sha256"

if ($Version -notmatch '^\d+\.\d+$') { throw "无效版本号：$Version" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '未找到 docker CLI' }
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { throw '未找到 tar 命令' }

$proxyClient = [System.Net.Sockets.TcpClient]::new()
try {
    $proxyClient.Connect('127.0.0.1', 7890)
    $env:HTTP_PROXY = 'http://127.0.0.1:7890'
    $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
    $env:NO_PROXY = 'localhost,127.0.0.1'
} catch {
    Write-Verbose '本机 7890 代理不可用，Docker CLI 使用系统网络配置'
} finally {
    $proxyClient.Dispose()
}

New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
$releaseRootFull = [System.IO.Path]::GetFullPath($releaseRoot)
foreach ($path in @($stageDir, $archivePath, $hashPath)) {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    if (-not $fullPath.StartsWith($releaseRootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理发布目录外路径：$fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction SilentlyContinue
}

$buildTime = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
& docker build --platform linux/amd64 --file $dockerfile --target export `
    --build-arg "VNTC_BUILD_TIME=$buildTime" `
    --output "type=local,dest=$stageDir" $projectDir
if ($LASTEXITCODE -ne 0) { throw 'Debian 12 原生二进制构建失败' }

Copy-Item -LiteralPath (Join-Path $projectDir 'linux_webui\config.example.json') -Destination (Join-Path $stageDir 'config.example.json')
Copy-Item -LiteralPath (Join-Path $projectDir 'linux_webui\systemd\vntc-linux-webui-root.service') -Destination (Join-Path $stageDir 'vntc-linux-webui.service')
Copy-Item -LiteralPath (Join-Path $projectDir 'linux_webui\README.md') -Destination (Join-Path $stageDir 'README.md')
[System.IO.File]::WriteAllText((Join-Path $stageDir 'VERSION'), "$Version`n", [System.Text.UTF8Encoding]::new($false))

$sumLines = Get-ChildItem -LiteralPath $stageDir -File | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($_.Name)"
}
[System.IO.File]::WriteAllLines((Join-Path $stageDir 'SHA256SUMS'), $sumLines, [System.Text.UTF8Encoding]::new($false))

& tar -C $releaseRoot -czf $archivePath $packageBase
if ($LASTEXITCODE -ne 0) { throw '原生发布包压缩失败' }
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText($hashPath, "$archiveHash  $([System.IO.Path]::GetFileName($archivePath))`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "原生发布包：$archivePath"
Write-Host "SHA256：$archiveHash"
