[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoExport
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$cargoToml = Join-Path $projectDir 'linux_webui\Cargo.toml'
$dockerfile = Join-Path $projectDir 'linux_webui\docker\Dockerfile'
$composeFile = Join-Path $projectDir 'linux_webui\docker\compose.yaml'
$dockerReadme = Join-Path $projectDir 'linux_webui\docker\README.md'
$loadScript = Join-Path $projectDir 'linux_webui\docker\load-image.sh'
$releaseDir = Join-Path $projectDir 'release\docker'
$cliProxy = 'http://127.0.0.1:7890'

if ([string]::IsNullOrWhiteSpace($Version)) {
    $cargoContent = Get-Content -LiteralPath $cargoToml -Raw
    $match = [regex]::Match($cargoContent, '(?m)^version\s*=\s*"(\d+\.\d+)\.\d+"')
    if (-not $match.Success) {
        throw '无法从 linux_webui/Cargo.toml 读取版本号'
    }
    $Version = $match.Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+$') {
    throw "无效 Docker 镜像版本：$Version"
}

function Test-DockerReady {
    try {
        & docker info *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw '未找到 docker CLI，请先安装 Docker Desktop 或 Docker Engine'
}

$proxyClient = [System.Net.Sockets.TcpClient]::new()
try {
    $proxyClient.Connect('127.0.0.1', 7890)
    $env:HTTP_PROXY = $cliProxy
    $env:HTTPS_PROXY = $cliProxy
    $env:NO_PROXY = 'localhost,127.0.0.1'
} catch {
    Write-Verbose '本机 7890 代理不可用，Docker CLI 使用系统网络配置'
} finally {
    $proxyClient.Dispose()
}

if (-not (Test-DockerReady)) {
    $desktopCandidates = @(
        @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
            (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($desktopCandidates.Count -eq 0) {
        throw 'Docker daemon 未运行，且未找到 Docker Desktop'
    }

    Write-Host 'Docker Desktop 未运行，正在启动...'
    Start-Process -FilePath $desktopCandidates[0] -WindowStyle Hidden | Out-Null
    $ready = $false
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        Start-Sleep -Seconds 2
        if (Test-DockerReady) {
            $ready = $true
            break
        }
    }
    if (-not $ready) {
        throw '等待 Docker daemon 就绪超时'
    }
}

$image = "vntc-linux-webui:$Version"
Write-Host "[1/4] 校验 Compose"
& docker compose --file $composeFile config --quiet
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose 配置无效' }

Write-Host "[2/4] 构建 $image"
$buildArguments = @(
    'build',
    '--platform', 'linux/amd64',
    '--file', $dockerfile,
    '--build-arg', "APP_VERSION=$Version",
    '--build-arg', "VNTC_BUILD_TIME=$([DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))",
    '--tag', $image,
    '--tag', 'vntc-linux-webui:latest'
)
$buildArguments += $projectDir
& docker @buildArguments
if ($LASTEXITCODE -ne 0) { throw 'Docker 镜像构建失败' }

$inspect = & docker image inspect $image | ConvertFrom-Json
if ($inspect[0].Os -ne 'linux' -or $inspect[0].Architecture -ne 'amd64') {
    throw "镜像平台不符合预期：$($inspect[0].Os)/$($inspect[0].Architecture)"
}

if ($NoExport) {
    Write-Host "[3/4] 跳过离线镜像导出"
    Write-Host "[4/4] Docker 镜像构建完成：$image"
    exit 0
}

Write-Host '[3/4] 导出离线镜像包'
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
$baseName = "VNTC_Linux_WebUI_${Version}_Docker_amd64"
$tarPath = Join-Path $releaseDir "$baseName.tar"
$gzipPath = "$tarPath.gz"
$hashPath = "$gzipPath.sha256"

foreach ($path in @($tarPath, $gzipPath, $hashPath)) {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    $releaseFullPath = [System.IO.Path]::GetFullPath($releaseDir)
    if (-not $fullPath.StartsWith($releaseFullPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理发布目录外路径：$fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
}

& docker save --output $tarPath $image
if ($LASTEXITCODE -ne 0) { throw 'docker save 失败' }

$input = [System.IO.File]::OpenRead($tarPath)
try {
    $output = [System.IO.File]::Create($gzipPath)
    try {
        $gzip = [System.IO.Compression.GZipStream]::new(
            $output,
            [System.IO.Compression.CompressionLevel]::SmallestSize
        )
        try { $input.CopyTo($gzip) } finally { $gzip.Dispose() }
    } finally { $output.Dispose() }
} finally { $input.Dispose() }
Remove-Item -LiteralPath $tarPath -Force

$hash = (Get-FileHash -LiteralPath $gzipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $hashPath,
    "$hash  $([System.IO.Path]::GetFileName($gzipPath))`n",
    [System.Text.UTF8Encoding]::new($false)
)

Copy-Item -LiteralPath $composeFile -Destination (Join-Path $releaseDir 'compose.yaml') -Force
Copy-Item -LiteralPath $dockerReadme -Destination (Join-Path $releaseDir 'README.md') -Force
Copy-Item -LiteralPath $loadScript -Destination (Join-Path $releaseDir 'load-image.sh') -Force
[System.IO.File]::WriteAllText(
    (Join-Path $releaseDir '.env'),
    "VNTC_VERSION=$Version`n",
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host '[4/4] Docker 镜像包完成'
Write-Host "镜像：$image"
Write-Host "离线包：$gzipPath"
Write-Host "SHA256：$hash"
