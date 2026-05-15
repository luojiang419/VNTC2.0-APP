param(
    [string]$Version = "1.4.6"
)

$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $projectDir "third_party\rustdesk\windows\runtime"
$customFile = Join-Path $projectDir "third_party\rustdesk\windows\custom.txt"
$cacheDir = Join-Path $env:TEMP "vnt_rustdesk_cache"
$downloadPath = Join-Path $cacheDir "rustdesk-$Version-x86_64.msi"
$stageRoot = Join-Path $cacheDir "stage-$Version"
$smokeRoot = Join-Path $cacheDir "smoke-$Version"
$runtimeSourceFile = Join-Path $runtimeRoot "runtime-source.txt"

function Ensure-Directory {
    param(
        [string]$Path
    )

    if (!(Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Reset-Directory {
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Start-ManagedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [hashtable]$EnvironmentMap = @{}
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if ($Arguments -and $Arguments.Count -gt 0) {
        $psi.Arguments = ($Arguments -join ' ')
    }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($entry in $EnvironmentMap.GetEnumerator()) {
        $psi.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()
    return $process
}

function Stop-ManagedProcess {
    param(
        [System.Diagnostics.Process]$Process
    )

    if ($null -eq $Process) {
        return
    }

    if (!$Process.HasExited) {
        $Process.Kill()
        $null = $Process.WaitForExit(2000)
    }
}

function Read-ProcessStream {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$StreamName
    )

    if ($null -eq $Process) {
        return ""
    }

    try {
        if ($StreamName -eq "stdout") {
            return $Process.StandardOutput.ReadToEnd()
        }
        return $Process.StandardError.ReadToEnd()
    } catch {
        return ""
    }
}

function Expand-RustDeskRuntime {
    param(
        [string]$ArchivePath,
        [string]$TargetRoot
    )

    Reset-Directory -Path $TargetRoot
    $stageMsiRoot = Join-Path $TargetRoot "msi"
    Ensure-Directory -Path $stageMsiRoot

    Write-Host "[RustDesk] Expanding runtime into isolated staging: $TargetRoot"
    $process = Start-ManagedProcess `
        -FilePath "msiexec.exe" `
        -Arguments @(
            "/a",
            "`"$ArchivePath`"",
            "/qn",
            "TARGETDIR=`"$stageMsiRoot`""
        ) `
        -WorkingDirectory $TargetRoot

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Get-ChildItem -LiteralPath $TargetRoot -Recurse -Filter "rustdesk.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    Stop-ManagedProcess -Process $process
    $stdout = Read-ProcessStream -Process $process -StreamName "stdout"
    $stderr = Read-ProcessStream -Process $process -StreamName "stderr"

    $runtimeExe = Get-ChildItem -LiteralPath $TargetRoot -Recurse -Filter "rustdesk.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\packages\\' } |
        Select-Object -First 1

    if ($null -ne $runtimeExe) {
        $stageRuntimeRoot = Split-Path -Parent $runtimeExe.FullName
    }

    if (!(Test-Path -LiteralPath (Join-Path $stageRuntimeRoot "rustdesk.exe"))) {
        throw "RustDesk runtime was not extracted to $TargetRoot | stdout=$stdout | stderr=$stderr"
    }

    return @{
        RuntimeDir = $stageRuntimeRoot
        Stdout = $stdout
        Stderr = $stderr
        StageRoot = $stageMsiRoot
    }
}

function Test-RustDeskRuntimeSmoke {
    param(
        [string]$RuntimeRoot,
        [string]$Version
    )

    $smokeAppData = Join-Path $smokeRoot "appdata"
    $smokeLocalAppData = Join-Path $smokeRoot "localappdata"
    $smokeTemp = Join-Path $smokeRoot "temp"
    $smokeLogs = Join-Path $smokeRoot "logs"
    $smokeConfigFile = Join-Path $smokeAppData "RustDesk\config\RustDesk.toml"
    $smokeCurrentLog = Join-Path $smokeAppData "RustDesk\log\RustDesk_rCURRENT.log"

    Reset-Directory -Path $smokeRoot
    Ensure-Directory -Path $smokeAppData
    Ensure-Directory -Path $smokeLocalAppData
    Ensure-Directory -Path $smokeTemp
    Ensure-Directory -Path $smokeLogs

    $environmentMap = @{
        APPDATA      = $smokeAppData
        LOCALAPPDATA = $smokeLocalAppData
        TEMP         = $smokeTemp
        TMP          = $smokeTemp
    }

    Write-Host "[RustDesk] Running isolated runtime smoke check"
    $process = Start-ManagedProcess `
        -FilePath (Join-Path $RuntimeRoot "rustdesk.exe") `
        -Arguments @() `
        -WorkingDirectory $RuntimeRoot `
        -EnvironmentMap $environmentMap

    $artifactsReady = $false
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $smokeConfigFile) -or
            (Test-Path -LiteralPath $smokeCurrentLog)) {
            $artifactsReady = $true
            break
        }
        if ($process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    Stop-ManagedProcess -Process $process
    $stdout = Read-ProcessStream -Process $process -StreamName "stdout"
    $stderr = Read-ProcessStream -Process $process -StreamName "stderr"

    Set-Content -LiteralPath (Join-Path $smokeLogs "smoke.stdout.log") -Value $stdout
    Set-Content -LiteralPath (Join-Path $smokeLogs "smoke.stderr.log") -Value $stderr

    if ($stdout -match "os error 2" -or $stderr -match "os error 2") {
        throw "RustDesk runtime smoke check failed with os error 2 | stdout=$stdout | stderr=$stderr"
    }

    if ($stdout -match "RuntimeBroker_rustdesk\.exe" -or $stderr -match "RuntimeBroker_rustdesk\.exe") {
        throw "RustDesk runtime smoke check failed because RuntimeBroker_rustdesk.exe is missing or unusable | stdout=$stdout | stderr=$stderr"
    }

    if (-not $artifactsReady) {
        $startupLooksHealthy =
            ($stdout -match "flutter: _globalFFI init end") -or
            ($stdout -match "registerEventHandler native_ui") -or
            ($stdout -match "MultiWindowHandler")
        $benignSmokeAssetError =
            ($stderr -match 'Unable to load asset: "assets/win\.svg') -or
            ($stderr -match "Unable to load asset: `"assets/win\.svg")

        if ($startupLooksHealthy -and ([string]::IsNullOrWhiteSpace($stderr) -or $benignSmokeAssetError)) {
            Write-Warning "RustDesk runtime smoke check did not produce config or logs under $smokeRoot, but startup output indicates the runtime initialized successfully. Proceeding."
            if ($benignSmokeAssetError) {
                Write-Warning "RustDesk runtime smoke check reported a non-fatal asset load warning for assets/win.svg during isolated startup. Proceeding with packaging."
            }
            $artifactsReady = $true
        } else {
            throw "RustDesk runtime smoke check did not produce config or logs under $smokeRoot | stdout=$stdout | stderr=$stderr"
        }
    }

    return @{
        SmokeRoot = $smokeRoot
        ConfigPath = $smokeConfigFile
        CurrentLogPath = $smokeCurrentLog
    }
}

if (!(Test-Path -LiteralPath $customFile)) {
    throw "Missing custom RustDesk config: $customFile"
}

Ensure-Directory -Path $cacheDir

if (!(Test-Path -LiteralPath $downloadPath)) {
    $url = "https://github.com/rustdesk/rustdesk/releases/download/$Version/rustdesk-$Version-x86_64.msi"
    Write-Host "[RustDesk] Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $downloadPath
}

$expanded = Expand-RustDeskRuntime -ArchivePath $downloadPath -TargetRoot $stageRoot

if (Test-Path -LiteralPath $runtimeRoot) {
    Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

Write-Host "[RustDesk] Copying clean runtime to $runtimeRoot"
Copy-Item -Path (Join-Path $expanded.RuntimeDir "*") -Destination $runtimeRoot -Recurse -Force
Copy-Item -LiteralPath $customFile -Destination (Join-Path $runtimeRoot "custom.txt") -Force
Set-Content -LiteralPath (Join-Path $runtimeRoot "runtime-version.txt") -Value $Version -NoNewline

$mainRuntimeExe = Join-Path $runtimeRoot "rustdesk.exe"
$companionRuntimeExe = Join-Path $runtimeRoot "rustdesk_qs.exe"
if (Test-Path -LiteralPath $mainRuntimeExe) {
    Copy-Item -LiteralPath $mainRuntimeExe -Destination $companionRuntimeExe -Force
}

$smoke = Test-RustDeskRuntimeSmoke -RuntimeRoot $runtimeRoot -Version $Version

$metadata = @(
    "version=$Version"
    "generatedAt=$([DateTime]::UtcNow.ToString('o'))"
    "downloadPath=$downloadPath"
    "stageRoot=$stageRoot"
    "smokeRoot=$($smoke.SmokeRoot)"
    "smokeConfigPath=$($smoke.ConfigPath)"
    "smokeCurrentLogPath=$($smoke.CurrentLogPath)"
    "source=isolated-staging"
) -join "`r`n"
Set-Content -LiteralPath $runtimeSourceFile -Value $metadata

Write-Host "[RustDesk] Runtime ready: $runtimeRoot"
