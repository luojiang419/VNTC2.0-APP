param(
    [string]$ExecutablePath = 'C:\Program Files\VNT App\vnt_app.exe',
    [int]$MinimumWidth = 720,
    [int]$MinimumHeight = 540
)

$ErrorActionPreference = 'Stop'
# 只读诊断：查询系统实际收到的拖拽下限，不移动或缩放业务窗口。
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VntWindowLimits {
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MinMaxInfo {
        public Point Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message,
        IntPtr wparam, ref MinMaxInfo info, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    private delegate bool EnumWindowCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowCallback callback, IntPtr data);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    public static IntPtr FindRunnerWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, data) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            var name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            if (owner == pid && name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW") {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

$vntProcesses = @(Get-Process -Name vnt_app | Where-Object Path -EQ $ExecutablePath)
if ($vntProcesses.Count -ne 1) { throw 'Expected exactly one installed UI process' }
$vntHwnd = [VntWindowLimits]::FindRunnerWindow($vntProcesses[0].Id)
if ($vntHwnd -eq [IntPtr]::Zero) { throw 'UI process has no main window' }
$vntInfo = New-Object VntWindowLimits+MinMaxInfo
$vntResult = [IntPtr]::Zero
if ([VntWindowLimits]::SendMessageTimeout($vntHwnd, 0x24, [IntPtr]::Zero,
    [ref]$vntInfo, 2, 3000, [ref]$vntResult) -eq [IntPtr]::Zero) {
    throw 'WM_GETMINMAXINFO query failed or timed out'
}
$vntScale = [VntWindowLimits]::GetDpiForWindow($vntHwnd) / 96.0
if ($vntScale -le 0) { throw 'Cannot determine window DPI' }
$vntRect = New-Object VntWindowLimits+Rect
if (-not [VntWindowLimits]::GetClientRect($vntHwnd, [ref]$vntRect)) {
    throw 'Cannot read client bounds'
}
$vntWidth = $vntInfo.MinTrackSize.X / $vntScale
$vntHeight = $vntInfo.MinTrackSize.Y / $vntScale
[pscustomobject]@{
    ProcessId = $vntProcesses[0].Id
    Scale = $vntScale
    MinimumWidth = $vntWidth
    MinimumHeight = $vntHeight
    ClientWidth = ($vntRect.Right - $vntRect.Left) / $vntScale
    ClientHeight = ($vntRect.Bottom - $vntRect.Top) / $vntScale
    Passed = ($vntWidth -ge $MinimumWidth -and $vntHeight -ge $MinimumHeight)
} | ConvertTo-Json
if ($vntWidth -lt $MinimumWidth -or $vntHeight -lt $MinimumHeight) {
    throw 'Native resize minimum is below the required dashboard size'
}
