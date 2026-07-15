param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "VNTS2-Manager.exe")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "VNTS2 Manager EXE 只能在 Windows 上构建。"
}

$sourcePath = Join-Path $PSScriptRoot "gui\Vnts2Manager.cs"
$manifestPath = Join-Path $PSScriptRoot "gui\VNTS2-Manager.manifest"
$iconPath = Join-Path $PSScriptRoot "gui\VNTS2-Manager.ico"
$compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
foreach ($path in @($sourcePath, $manifestPath, $iconPath, $compiler)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "原生 GUI 构建依赖不存在：$path"
    }
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$buildDirectory = Join-Path $env:TEMP ("vnts2-manager-build-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
$buildSource = Join-Path $buildDirectory "Vnts2Manager.cs"
$buildManifest = Join-Path $buildDirectory "VNTS2-Manager.manifest"
$buildIcon = Join-Path $buildDirectory "VNTS2-Manager.ico"
$temporaryOutput = Join-Path $buildDirectory "VNTS2-Manager.exe"

try {
    Copy-Item -LiteralPath $sourcePath -Destination $buildSource
    Copy-Item -LiteralPath $manifestPath -Destination $buildManifest
    Copy-Item -LiteralPath $iconPath -Destination $buildIcon
    $arguments = @(
        "/nologo",
        "/target:winexe",
        "/platform:x64",
        "/optimize+",
        "/debug-",
        "/win32manifest:$buildManifest",
        "/win32icon:$buildIcon",
        "/out:$temporaryOutput",
        "/reference:System.dll",
        "/reference:System.Core.dll",
        "/reference:System.Drawing.dll",
        "/reference:System.Windows.Forms.dll",
        "/reference:System.Web.Extensions.dll",
        $buildSource
    )
    $compilerOutput = & $compiler $arguments 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryOutput -PathType Leaf)) {
        throw "C# WinForms 编译失败：`r`n$(($compilerOutput | Out-String).Trim())"
    }

    $validationPath = Join-Path $env:TEMP ("vnts2-manager-validation-{0}.json" -f [Guid]::NewGuid().ToString("N"))
    try {
        $process = Start-Process `
            -FilePath $temporaryOutput `
            -ArgumentList @("--validate-only", "`"$validationPath`"") `
            -Wait `
            -PassThru
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $validationPath -PathType Leaf)) {
            throw "原生 GUI 验证模式失败（退出码 $($process.ExitCode)）。"
        }
        $model = Get-Content -LiteralPath $validationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($model.Implementation -ne "CSharpWinForms" -or -not $model.ExecutableGui -or $model.UsesPowerShellGui) {
            throw "原生 GUI 验证模型不符合约定。"
        }
    } finally {
        if (Test-Path -LiteralPath $validationPath -PathType Leaf) {
            Remove-Item -LiteralPath $validationPath -Force
        }
    }

    Move-Item -LiteralPath $temporaryOutput -Destination $resolvedOutput -Force
    $file = Get-Item -LiteralPath $resolvedOutput
    [pscustomobject]@{
        Path = $file.FullName
        Length = $file.Length
        SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
        Implementation = "CSharpWinForms"
        Platform = "x64"
    }
} finally {
    if (Test-Path -LiteralPath $buildDirectory -PathType Container) {
        Remove-Item -LiteralPath $buildDirectory -Recurse -Force
    }
}
