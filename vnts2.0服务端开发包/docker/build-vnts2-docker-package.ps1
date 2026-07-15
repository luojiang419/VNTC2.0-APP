[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $scriptDir
$distDir = Join-Path $packageRoot 'dist'
$image = 'vnts2:2.0.0'
$archiveName = 'vnts2-2.0.0-docker-linux-amd64.tar.gz'
$archivePath = Join-Path $distDir $archiveName
$temporaryTar = Join-Path $distDir 'vnts2-2.0.0-docker-linux-amd64.tmp.tar'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw '缺少 docker 命令。'
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Linux 引擎未运行。'
}

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
try {
    docker build --pull --platform linux/amd64 `
        --file (Join-Path $scriptDir 'Dockerfile') `
        --tag $image `
        $packageRoot
    if ($LASTEXITCODE -ne 0) { throw 'Docker 镜像构建失败。' }

    docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) { throw '构建后的 Docker 镜像不存在。' }

    docker save --output $temporaryTar $image
    if ($LASTEXITCODE -ne 0) { throw 'Docker 镜像导出失败。' }

    $inputStream = [System.IO.File]::OpenRead($temporaryTar)
    try {
        $outputStream = [System.IO.File]::Create($archivePath)
        try {
            $gzipStream = [System.IO.Compression.GZipStream]::new(
                $outputStream,
                [System.IO.Compression.CompressionLevel]::SmallestSize,
                $true
            )
            try { $inputStream.CopyTo($gzipStream) } finally { $gzipStream.Dispose() }
        } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }

    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$archivePath.sha256",
        "$hash  $archiveName`n",
        [System.Text.UTF8Encoding]::new($false)
    )
} finally {
    Remove-Item -LiteralPath $temporaryTar -Force -ErrorAction SilentlyContinue
}

Write-Output "Docker 离线镜像包已生成：$archivePath"
