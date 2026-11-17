param(
    [Parameter(Mandatory = $true)][string]$SetupPath
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw '此验收仅用于隔离的 GitHub Windows Runner，禁止操作本机业务服务'
}
if (Get-Service VntCoreService -ErrorAction SilentlyContinue) {
    throw '发现已有 VNT 核心服务，拒绝覆盖'
}
$setup = (Resolve-Path -LiteralPath $SetupPath).Path
$runnerRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$appRoot = [IO.Path]::GetFullPath((Join-Path $runnerRoot 'VNT Service Install Test'))
if (-not $appRoot.StartsWith($runnerRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw '安装验收目录超出 Runner 临时目录'
}
try {
    # 同一路径安装两次，覆盖新装及已有服务的升级分支；路径故意包含空格。
    foreach ($attempt in 1..2) {
        $log = Join-Path $runnerRoot "vnt-installer-service-$attempt.log"
        $process = Start-Process -FilePath $setup -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
            ('/DIR="{0}"' -f $appRoot), ('/LOG="{0}"' -f $log)
        ) -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw "安装器退出码 $($process.ExitCode)，日志 $log" }
        $service = Get-CimInstance Win32_Service -Filter "Name='VntCoreService'"
        $expected = '"' + (Join-Path $appRoot 'vnt_service.exe') + '"'
        if ($service.State -ne 'Running' -or $service.StartMode -ne 'Auto' -or
            $service.PathName -ne $expected) {
            throw "服务安装验收失败：state=$($service.State), path=$($service.PathName)"
        }
        Write-Host "[OK] 安装轮次 $attempt：服务运行，含空格路径保留引号"
    }
} finally {
    $uninstaller = Join-Path $appRoot 'unins000.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        $cleanup = Start-Process -FilePath $uninstaller -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
        ) -WindowStyle Hidden -PassThru -Wait
        if ($cleanup.ExitCode -ne 0) { Write-Warning "验收卸载退出码 $($cleanup.ExitCode)" }
    }
}
