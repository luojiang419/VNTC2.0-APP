param(
  [string]$AppDir,
  [int]$WaitSeconds = 8,
  [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"

function Resolve-AppDir {
  param([string]$Provided)

  if (-not [string]::IsNullOrWhiteSpace($Provided)) {
    return (Resolve-Path -LiteralPath $Provided).Path
  }

  $candidates = @(
    $PSScriptRoot,
    (Join-Path $PSScriptRoot "..\output"),
    (Join-Path $PSScriptRoot "..\dist")
  )

  foreach ($candidate in $candidates) {
    try {
      $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
      if (Test-Path -LiteralPath (Join-Path $resolved "vnt_app.exe")) {
        return $resolved
      }
    } catch {
      continue
    }
  }

  throw "未找到包含 vnt_app.exe 的目录，请显式传入 -AppDir"
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Rotate-Log([string]$Path, [string]$Stamp) {
  if (Test-Path -LiteralPath $Path) {
    Move-Item -LiteralPath $Path -Destination "$Path.$Stamp.prev" -Force
  }
}

function Read-Tail([string]$Path, [int]$Count = 120) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return @("<missing>")
  }
  try {
    return Get-Content -LiteralPath $Path -Tail $Count -ErrorAction Stop
  } catch {
    return @("<< failed to read $Path : $($_.Exception.Message) >>")
  }
}

function Get-ConfigContent([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return "<missing>"
  }
  return Get-Content -LiteralPath $Path -Raw
}

function Stop-AppProcesses([string]$ExeDir) {
  $targets = @(
    (Join-Path $ExeDir "vnt_app.exe"),
    (Join-Path $ExeDir "vnt_app_runner.exe")
  ) | ForEach-Object { $_.ToLowerInvariant() }

  $processes = Get-CimInstance Win32_Process -Filter "Name='vnt_app.exe' OR Name='vnt_app_runner.exe'" -ErrorAction SilentlyContinue
  foreach ($process in $processes) {
    $path = if ($null -ne $process.ExecutablePath) {
      $process.ExecutablePath.ToLowerInvariant()
    } else {
      ""
    }
    if ($targets -contains $path) {
      try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
      } catch {}
    }
  }
}

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowProbe {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
"@

function Get-WindowInfoForProcess([int]$ProcessId) {
  $windows = New-Object System.Collections.Generic.List[object]
  $callback = [WindowProbe+EnumWindowsProc]{
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    $procId = 0
    [WindowProbe]::GetWindowThreadProcessId($hWnd, [ref]$procId) | Out-Null
    if ($procId -ne $ProcessId) {
      return $true
    }
    if (-not [WindowProbe]::IsWindowVisible($hWnd)) {
      return $true
    }
    $rect = New-Object WindowProbe+RECT
    [WindowProbe]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
    $length = [WindowProbe]::GetWindowTextLength($hWnd)
    $builder = New-Object System.Text.StringBuilder ($length + 1)
    [WindowProbe]::GetWindowText($hWnd, $builder, $builder.Capacity) | Out-Null
    $windows.Add([pscustomobject]@{
      Handle = ('0x{0:X}' -f $hWnd.ToInt64())
      Title = $builder.ToString()
      Left = $rect.Left
      Top = $rect.Top
      Right = $rect.Right
      Bottom = $rect.Bottom
      Width = $rect.Right - $rect.Left
      Height = $rect.Bottom - $rect.Top
    }) | Out-Null
    return $true
  }
  [WindowProbe]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
  return $windows
}

function Test-WindowVisibleOnScreens($Window, $Screens) {
  foreach ($screen in $Screens) {
    $left = [Math]::Max($Window.Left, $screen.WorkingArea.Left)
    $top = [Math]::Max($Window.Top, $screen.WorkingArea.Top)
    $right = [Math]::Min($Window.Right, $screen.WorkingArea.Right)
    $bottom = [Math]::Min($Window.Bottom, $screen.WorkingArea.Bottom)
    if (($right - $left) -ge 80 -and ($bottom - $top) -ge 60) {
      return $true
    }
  }
  return $false
}

$resolvedAppDir = Resolve-AppDir -Provided $AppDir
$logsDir = Join-Path $resolvedAppDir "logs"
$configPath = Join-Path $resolvedAppDir "config\config.json"
$exePath = Join-Path $resolvedAppDir "vnt_app.exe"
$runnerPath = Join-Path $resolvedAppDir "vnt_app_runner.exe"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $logsDir "portable_launch_diag_$stamp.md"
$launcherLog = Join-Path $logsDir "launcher.log"
$bootTraceLog = Join-Path $logsDir "boot_trace.log"
$coreLog = Join-Path $logsDir "vnt-core.log"

Ensure-Directory $logsDir
Rotate-Log -Path $launcherLog -Stamp $stamp
Rotate-Log -Path $bootTraceLog -Stamp $stamp

Stop-AppProcesses -ExeDir $resolvedAppDir

$screens = [System.Windows.Forms.Screen]::AllScreens
$screenLines = @()
foreach ($screen in $screens) {
  $screenLines += "- DeviceName: $($screen.DeviceName) Bounds=$($screen.Bounds) WorkingArea=$($screen.WorkingArea) Primary=$($screen.Primary)"
}

$process = Start-Process -FilePath $exePath -WorkingDirectory $resolvedAppDir -PassThru
Start-Sleep -Seconds $WaitSeconds

$processSnapshot = Get-CimInstance Win32_Process -Filter "Name='vnt_app.exe' OR Name='vnt_app_runner.exe'" -ErrorAction SilentlyContinue |
  Select-Object ProcessId, Name, ExecutablePath, CommandLine

$runnerProc = $processSnapshot | Where-Object {
  $exePathLower = if ($null -ne $_.ExecutablePath) {
    $_.ExecutablePath.ToLowerInvariant()
  } else {
    ""
  }
  $exePathLower -eq $runnerPath.ToLowerInvariant()
} | Select-Object -First 1

$windowInfo = @()
$windowVisibleOnScreen = $false
if ($runnerProc) {
  $windowInfo = @(Get-WindowInfoForProcess -ProcessId $runnerProc.ProcessId)
  if ($windowInfo.Count -gt 0) {
    $windowVisibleOnScreen = $windowInfo | Where-Object {
      Test-WindowVisibleOnScreens $_ $screens
    } | Select-Object -First 1
    $windowVisibleOnScreen = [bool]$windowVisibleOnScreen
  }
}

if (-not $KeepRunning) {
  Stop-AppProcesses -ExeDir $resolvedAppDir
}

$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add('# Portable Launch Diagnostic')
$lines.Add('')
$lines.Add("- Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("- AppDir: $resolvedAppDir")
$lines.Add("- WaitSeconds: $WaitSeconds")
$lines.Add("- LauncherShortLivedExpected: true")
$lines.Add("- RunnerDetected: $([bool]$runnerProc)")
$lines.Add("- VisibleWindowDetected: $windowVisibleOnScreen")
$lines.Add('')
$lines.Add('## Screen Snapshot')
$lines.Add('')
if ($screenLines.Count -eq 0) {
  $lines.Add('- (no screens detected)')
} else {
  $screenLines | ForEach-Object { $lines.Add($_) }
}
$lines.Add('')
$lines.Add('## Process Snapshot')
$lines.Add('')
$lines.Add('```text')
if ($processSnapshot) {
  $processSnapshot | ForEach-Object {
    $lines.Add("PID=$($_.ProcessId) Name=$($_.Name) Path=$($_.ExecutablePath)")
  }
} else {
  $lines.Add('<no matching process>')
}
$lines.Add('```')
$lines.Add('')
$lines.Add('## Window Snapshot')
$lines.Add('')
$lines.Add('```text')
if ($windowInfo.Count -gt 0) {
  $windowInfo | ForEach-Object {
    $lines.Add("Handle=$($_.Handle) Title=$($_.Title) Rect=[$($_.Left),$($_.Top),$($_.Right),$($_.Bottom)] Size=${($_.Width)}x${($_.Height)}")
  }
} else {
  $lines.Add('<no visible top-level window found for vnt_app_runner.exe>')
}
$lines.Add('```')
$lines.Add('')
$lines.Add('## Config Snapshot')
$lines.Add('')
$lines.Add('```json')
$lines.Add((Get-ConfigContent -Path $configPath))
$lines.Add('```')
$lines.Add('')
$lines.Add('## launcher.log Tail')
$lines.Add('')
$lines.Add('```text')
(Read-Tail -Path $launcherLog -Count 120) | ForEach-Object { $lines.Add($_) }
$lines.Add('```')
$lines.Add('')
$lines.Add('## boot_trace.log Tail')
$lines.Add('')
$lines.Add('```text')
(Read-Tail -Path $bootTraceLog -Count 200) | ForEach-Object { $lines.Add($_) }
$lines.Add('```')
$lines.Add('')
$lines.Add('## vnt-core.log Tail')
$lines.Add('')
$lines.Add('```text')
(Read-Tail -Path $coreLog -Count 120) | ForEach-Object { $lines.Add($_) }
$lines.Add('```')

$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "[Diag] Report written to $reportPath"
