param(
  [int]$WaitSeconds = 12,
  [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"

$projectDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildBat = Join-Path $PSScriptRoot "build_windows.bat"
$outputDir = Join-Path $projectDir "output"
$logsDir = Join-Path $outputDir "logs"
$launcherLog = Join-Path $logsDir "launcher.log"
$bootTraceLog = Join-Path $logsDir "boot_trace.log"
$coreLog = Join-Path $logsDir "vnt-core.log"
$exePath = Join-Path $outputDir "vnt_app.exe"
$timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$buildLog = Join-Path $logsDir "build_windows_$timeStamp.log"
$reportPath = Join-Path $logsDir "windows_release_diag_$timeStamp.md"
$werRoots = @(
  (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportArchive"),
  (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportQueue")
)
$crashDumpDir = Join-Path $env:LOCALAPPDATA "CrashDumps"
$launchedProcess = $null

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Rotate-Log([string]$Path, [string]$Stamp) {
  if (Test-Path $Path) {
    $backupPath = "$Path.$Stamp.prev"
    Move-Item -Path $Path -Destination $backupPath -Force
  }
}

function Invoke-TextCommand([scriptblock]$Command) {
  try {
    $output = & $Command 2>&1 | Out-String
    return $output.TrimEnd()
  } catch {
    return ($_ | Out-String).TrimEnd()
  }
}

function Read-Tail([string]$Path, [int]$Count = 120, [string]$Encoding = "UTF8") {
  if (-not (Test-Path $Path)) {
    return @()
  }

  try {
    return Get-Content -Path $Path -Tail $Count -Encoding $Encoding -ErrorAction Stop
  } catch {
    return @("<< failed to read $Path : $($_.Exception.Message) >>")
  }
}

function Get-LatestWerReports() {
  $items = @()
  foreach ($root in $werRoots) {
    if (Test-Path $root) {
      $items += Get-ChildItem -Path $root -Recurse -Filter "Report.wer" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "vnt_app" }
    }
  }

  return $items | Sort-Object LastWriteTime -Descending | Select-Object -First 5
}

function Parse-WerReport([string]$Path) {
  $result = [ordered]@{
    Path = $Path
  }

  try {
    $lines = Get-Content -Path $Path -Encoding Unicode -ErrorAction Stop
  } catch {
    $result.ReadError = $_.Exception.Message
    return [pscustomobject]$result
  }

  foreach ($line in $lines) {
    if ($line -match "^NsAppName=(.+)$") {
      $result.AppName = $Matches[1]
      continue
    }
    if ($line -match "^AppPath=(.+)$") {
      $result.AppPath = $Matches[1]
      continue
    }
    if ($line -match "^TargetAppVer=(.+)$") {
      $result.TargetAppVer = $Matches[1]
      continue
    }
    if ($line -match "^Sig\[3\]\.Value=(.+)$") {
      $result.FaultModule = $Matches[1]
      continue
    }
    if ($line -match "^Sig\[6\]\.Value=(.+)$") {
      $result.ExceptionOffset = $Matches[1]
      continue
    }
    if ($line -match "^Sig\[7\]\.Value=(.+)$") {
      $result.ExceptionCode = $Matches[1]
      continue
    }
    if ($line -match "^DynamicSig\[1\]\.Value=(.+)$") {
      $result.OsVersion = $Matches[1]
      continue
    }
    if ($line -match "^UI\[2\]=(.+)$") {
      $result.UiTargetPath = $Matches[1]
      continue
    }
  }

  return [pscustomobject]$result
}

function Get-CrashDumps() {
  if (-not (Test-Path $crashDumpDir)) {
    return @()
  }

  return Get-ChildItem -Path $crashDumpDir -Filter "vnt_app_runner.exe*.dmp" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5
}

function Add-MarkdownSection(
  [System.Collections.Generic.List[string]]$Lines,
  [string]$Title,
  [string[]]$Content
) {
  $Lines.Add("## $Title")
  $Lines.Add("")
  if ($Content.Count -eq 0) {
    $Lines.Add("- (empty)")
  } else {
    foreach ($line in $Content) {
      $Lines.Add($line)
    }
  }
  $Lines.Add("")
}

Ensure-Directory $logsDir

Rotate-Log -Path $launcherLog -Stamp $timeStamp
Rotate-Log -Path $bootTraceLog -Stamp $timeStamp
Rotate-Log -Path $coreLog -Stamp $timeStamp

$flutterVersion = Invoke-TextCommand { flutter --version }
$cargoVersion = Invoke-TextCommand { cargo --version }
$rustcVersion = Invoke-TextCommand { rustc --version }
$gitStatus = Invoke-TextCommand { git -C $projectDir status --short }

$buildOutput = & $env:ComSpec /d /c "`"$buildBat`"" 2>&1
$buildExitCode = $LASTEXITCODE
$buildOutput | Set-Content -Path $buildLog -Encoding UTF8

$launchStatus = "build_failed"
$runningProcesses = @()

if ($buildExitCode -eq 0 -and (Test-Path $exePath)) {
  $launchedProcess = Start-Process -FilePath $exePath -WorkingDirectory $outputDir -PassThru
  $launchStatus = "started"
  Start-Sleep -Seconds $WaitSeconds
  $runningProcesses = Get-Process -Name "vnt_app", "vnt_app_runner" -ErrorAction SilentlyContinue |
    Sort-Object ProcessName

  if ($runningProcesses.Count -gt 0) {
    $launchStatus = "running_after_wait"
  } else {
    $launchStatus = "exited_before_wait_end"
  }
}

$werReports = @(Get-LatestWerReports | ForEach-Object { Parse-WerReport $_.FullName })
$crashDumps = @(Get-CrashDumps)

if (-not $KeepRunning) {
  Get-Process -Name "vnt_app_runner", "vnt_app" -ErrorAction SilentlyContinue | Stop-Process -Force
}

$launcherTail = @(Read-Tail -Path $launcherLog -Count 120)
$bootTraceTail = @(Read-Tail -Path $bootTraceLog -Count 120)
$coreLogTail = @(Read-Tail -Path $coreLog -Count 120)

$lines = New-Object "System.Collections.Generic.List[string]"
$lines.Add("# Windows Release Diagnostic")
$lines.Add("")
$lines.Add("- Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("- Project: `$projectDir`")
$lines.Add("- Build script: `$buildBat`")
$lines.Add("- Build exit code: $buildExitCode")
$lines.Add("- Launch status: $launchStatus")
$lines.Add("- Wait seconds: $WaitSeconds")
$lines.Add("- Keep running: $KeepRunning")
$lines.Add("- Build log: `$buildLog`")
$lines.Add("")

Add-MarkdownSection -Lines $lines -Title "Tool Versions" -Content @(
  "```text",
  $flutterVersion,
  $cargoVersion,
  $rustcVersion,
  "```"
)

Add-MarkdownSection -Lines $lines -Title "Git Status" -Content @(
  "```text",
  ($gitStatus | ForEach-Object { $_ }),
  "```"
)

Add-MarkdownSection -Lines $lines -Title "Build Output Tail" -Content @(
  "```text",
  ($buildOutput | Select-Object -Last 80 | ForEach-Object { "$_" }),
  "```"
)

$processLines = @()
foreach ($process in $runningProcesses) {
  $processLines += "- $($process.ProcessName) pid=$($process.Id) start=$($process.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}
if ($processLines.Count -eq 0) {
  $processLines += "- no vnt_app / vnt_app_runner process alive after wait window"
}
Add-MarkdownSection -Lines $lines -Title "Process State" -Content $processLines

$werLines = @()
foreach ($report in $werReports) {
  $werLines += "- Path: `$($report.Path)`"
  if ($report.AppName) { $werLines += "  App: `$($report.AppName)`" }
  if ($report.AppPath) { $werLines += "  AppPath: `$($report.AppPath)`" }
  if ($report.TargetAppVer) { $werLines += "  TargetAppVer: `$($report.TargetAppVer)`" }
  if ($report.FaultModule) { $werLines += "  FaultModule: `$($report.FaultModule)`" }
  if ($report.ExceptionOffset) { $werLines += "  ExceptionOffset: `$($report.ExceptionOffset)`" }
  if ($report.ExceptionCode) { $werLines += "  ExceptionCode: `$($report.ExceptionCode)`" }
  if ($report.OsVersion) { $werLines += "  OsVersion: `$($report.OsVersion)`" }
  if ($report.UiTargetPath) { $werLines += "  UiTargetPath: `$($report.UiTargetPath)`" }
}
if ($werLines.Count -eq 0) {
  $werLines += "- no vnt_app WER report found"
}
Add-MarkdownSection -Lines $lines -Title "WER Reports" -Content $werLines

$dumpLines = @()
foreach ($dump in $crashDumps) {
  $dumpLines += "- `$($dump.FullName)` size=$($dump.Length) last_write=$($dump.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}
if ($dumpLines.Count -eq 0) {
  $dumpLines += "- no vnt_app_runner crash dump found"
}
Add-MarkdownSection -Lines $lines -Title "Crash Dumps" -Content $dumpLines

Add-MarkdownSection -Lines $lines -Title "launcher.log Tail" -Content @(
  "```text",
  ($launcherTail | ForEach-Object { "$_" }),
  "```"
)

Add-MarkdownSection -Lines $lines -Title "boot_trace.log Tail" -Content @(
  "```text",
  ($bootTraceTail | ForEach-Object { "$_" }),
  "```"
)

Add-MarkdownSection -Lines $lines -Title "vnt-core.log Tail" -Content @(
  "```text",
  ($coreLogTail | ForEach-Object { "$_" }),
  "```"
)

$lines | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "[OK] Diagnostic report written to $reportPath"
Write-Host "[OK] Build log written to $buildLog"

if (Test-Path $reportPath) {
  Get-Content -Path $reportPath -Encoding UTF8
}
