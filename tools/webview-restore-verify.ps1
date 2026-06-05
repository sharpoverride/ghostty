param([string]$Out="E:\ghosttty\tools\webview-restore-verify.png")
# Verifies browser-tab session persistence:
#   run 1: auto-open browser tab, navigate to example.com, graceful WM_CLOSE
#          (saves session.json with kind=browser + url)
#   run 2: plain launch → restore should recreate the browser tab at the
#          saved URL. PrintWindow capture (works on a locked desktop).
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

function MainHwnd($proc) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq 0) {
        $g = Get-Process -Name ghostty -ErrorAction SilentlyContinue | ?{ $_.MainWindowHandle -ne 0 } | select -First 1
        if ($g) { $h = $g.MainWindowHandle }
    }
    return $h
}
function FindEdit($h) {
    $hostW = [U]::FindWindowExW($h, [IntPtr]::Zero, "Static", $null)
    if ($hostW -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    return [U]::FindWindowExW($hostW, [IntPtr]::Zero, "Edit", $null)
}
function BarText($edit) {
    $sb = New-Object System.Text.StringBuilder 2048
    [void][U]::SendMessageW($edit, 0x000D, [IntPtr]::new(2048), $sb)
    return $sb.ToString()
}

# ---- run 1: open browser, navigate, graceful close ----
$env:GHOSTTY_OPEN_BROWSER = "1"
$p = Start-Process -FilePath "E:\ghosttty\zig-out\bin\ghostty.exe" `
    -RedirectStandardError "E:\ghosttty\tools\webview-restore-run1.log" `
    -RedirectStandardOutput "E:\ghosttty\tools\webview-restore-run1.out" -PassThru
Start-Sleep -Seconds 12
$h = MainHwnd $p
if ($h -eq 0) { "RUN1_NO_WINDOW"; exit 1 }
$edit = FindEdit $h
if ($edit -eq [IntPtr]::Zero) { "RUN1_NO_EDIT"; exit 1 }
[void][U]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, "example.com")
[void][U]::PostMessageW($edit, 0x0100, [IntPtr]::new(0x0D), [IntPtr]::Zero)
Start-Sleep -Seconds 6
"RUN1_BAR $(BarText $edit)"
[void][U]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE → saveSession
Start-Sleep -Seconds 4
if (-not $p.HasExited) { "RUN1_NO_EXIT"; Stop-Process -Id $p.Id -Force; exit 1 }
"RUN1_CLOSED"

# Manifest should record the browser tab.
$manifest = Get-Content "$env:APPDATA\ghostty\session\session.json" -Raw
if ($manifest -match '"browser"') { "MANIFEST_HAS_BROWSER" } else { "MANIFEST_MISSING_BROWSER"; $manifest; exit 1 }

# ---- run 2: plain launch, expect restore ----
Remove-Item Env:\GHOSTTY_OPEN_BROWSER
$p2 = Start-Process -FilePath "E:\ghosttty\zig-out\bin\ghostty.exe" `
    -RedirectStandardError "E:\ghosttty\tools\webview-restore-run2.log" `
    -RedirectStandardOutput "E:\ghosttty\tools\webview-restore-run2.out" -PassThru
Start-Sleep -Seconds 12
$h2 = MainHwnd $p2
if ($h2 -eq 0) { "RUN2_NO_WINDOW"; exit 1 }
$edit2 = FindEdit $h2
if ($edit2 -eq [IntPtr]::Zero) { "RUN2_NO_EDIT (browser tab not restored?)"; exit 1 }
"RUN2_BAR $(BarText $edit2)"

# Switch to the browser tab so the capture shows it: it may not be active.
# The restored browser tab is the last one; click simulation is unreliable
# on a locked desktop, so capture whatever is active — BAR text above is
# the real assertion. Still try to make it visible via Ctrl+Tab cycling is
# overkill; just capture.
$r = New-Object U+R
[void][U]::GetClientRect($h2, [ref]$r)
$w = $r.rr - $r.l; $ht = $r.b - $r.t
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [U]::PrintWindow($h2, $hdc, 2)
$g.ReleaseHdc($hdc); $g.Dispose()
$bmp.Save($Out); $bmp.Dispose()
"PrintWindow=$ok $w x $ht -> $Out"

Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue
