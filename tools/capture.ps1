# Capture a window's client area to a PNG by process name.
# Usage: powershell -File capture.ps1 <procName> <outPath>
param(
    [string]$ProcName = "ghostty",
    [string]$Out = "E:\ghosttty\.shot.png"
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public struct RECT { public int left, top, right, bottom; }
    public struct POINT { public int x, y; }
}
"@

$p = Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "NO_WINDOW"; exit 1 }
$h = $p.MainWindowHandle
[void][WinCap]::ShowWindow($h, 5)         # SW_SHOW
# Force topmost so nothing occludes the client area during CopyFromScreen.
# HWND_TOPMOST = -1; flags = SWP_NOMOVE|SWP_NOSIZE = 0x0002|0x0001 = 0x0003.
[void][WinCap]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003)
[void][WinCap]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 500

$rect = New-Object WinCap+RECT
[void][WinCap]::GetClientRect($h, [ref]$rect)
$w = $rect.right - $rect.left
$ht = $rect.bottom - $rect.top
if ($w -le 0 -or $ht -le 0) { Write-Output "BAD_RECT $w x $ht"; exit 1 }

$tl = New-Object WinCap+POINT
$tl.x = 0; $tl.y = 0
[void][WinCap]::ClientToScreen($h, [ref]$tl)

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
# Screen-copy the client area (captures GPU-composited DXGI content, which
# PrintWindow often misses for hardware-accelerated swap chains).
$g.CopyFromScreen($tl.x, $tl.y, 0, 0, (New-Object System.Drawing.Size $w, $ht))
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "OK $w x $ht -> $Out"
