param([string]$Out="E:\ghosttty\tools\webview-nav-verify2.png")
# Lock-screen-proof variant of webview-nav-verify: PrintWindow with
# PW_RENDERFULLCONTENT instead of CopyFromScreen, and WM_GETTEXT via
# SendMessage (GetWindowTextW doesn't cross processes for controls).
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;using System.Text;
public class U{
 [DllImport("user32.dll")]public static extern bool GetClientRect(IntPtr h,out R r);
 [DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr hdc,uint flags);
 [DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr FindWindowExW(IntPtr parent,IntPtr after,string cls,string title);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
 [DllImport("user32.dll")]public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 public struct R{public int l,t,rr,b;}
}
"@
[void][U]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$env:GHOSTTY_OPEN_BROWSER = "1"
$log = "E:\ghosttty\tools\webview-nav-run.log"
if (Test-Path $log) { Remove-Item $log }
$p = Start-Process -FilePath "E:\ghosttty\zig-out\bin\ghostty.exe" `
    -RedirectStandardError $log -RedirectStandardOutput "E:\ghosttty\tools\webview-nav-run.out" `
    -PassThru
Start-Sleep -Seconds 12   # window + shell + WebView2 first-run

$p.Refresh()
$h = $p.MainWindowHandle
if ($h -eq 0) {
    $g0 = Get-Process -Name ghostty -ErrorAction SilentlyContinue | ?{ $_.MainWindowHandle -ne 0 } | select -First 1
    if ($g0) { $h = $g0.MainWindowHandle }
}
if ($h -eq 0) { "NO_WINDOW"; exit 1 }

$hostW = [U]::FindWindowExW($h, [IntPtr]::Zero, "Static", $null)
if ($hostW -eq [IntPtr]::Zero) { "NO_HOST"; exit 1 }
$edit = [U]::FindWindowExW($hostW, [IntPtr]::Zero, "Edit", $null)
if ($edit -eq [IntPtr]::Zero) { "NO_EDIT"; exit 1 }
"EDIT_HWND $edit"

function BarText {
    $sb = New-Object System.Text.StringBuilder 2048
    [void][U]::SendMessageW($edit, 0x000D, [IntPtr]::new(2048), $sb)  # WM_GETTEXT
    return $sb.ToString()
}
"BAR_BEFORE $(BarText)"

[void][U]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, "example.com") # WM_SETTEXT
[void][U]::PostMessageW($edit, 0x0100, [IntPtr]::new(0x0D), [IntPtr]::Zero) # VK_RETURN
Start-Sleep -Seconds 6
"BAR_AFTER $(BarText)"

function Capture($path){
    $r = New-Object U+R
    [void][U]::GetClientRect($h, [ref]$r)
    $w = $r.rr - $r.l; $ht = $r.b - $r.t
    if ($w -le 0) { "BAD_RECT"; return }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [U]::PrintWindow($h, $hdc, 2)  # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($path); $bmp.Dispose()
    "PrintWindow=$ok $w x $ht -> $path"
}
Capture $Out

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
