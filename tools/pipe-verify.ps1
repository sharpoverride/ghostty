param([string]$Out="E:\ghosttty\tools\pipe-verify.png")
# End-to-end verification of the named-pipe control API via ghostty-ctl:
#   list → open-browser → list (url visible) → eval document.title →
#   eval DOM query → navigate → switch → negative eval on a terminal tab.
# PrintWindow capture at the end (works on a locked desktop).
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class U{
 [DllImport("user32.dll")]public static extern bool GetClientRect(IntPtr h,out R r);
 [DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr hdc,uint flags);
 [DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
 public struct R{public int l,t,rr,b;}
}
"@
[void][U]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$ctl = "E:\ghosttty\zig-out\bin\ghostty-ctl.exe"
$p = Start-Process -FilePath "E:\ghosttty\zig-out\bin\ghostty.exe" `
    -RedirectStandardError "E:\ghosttty\tools\pipe-run.log" `
    -RedirectStandardOutput "E:\ghosttty\tools\pipe-run.out" -PassThru
Start-Sleep -Seconds 8
$pipeName = "\\.\pipe\ghostty-$($p.Id)"
"PIPE $pipeName"

function Ctl { param([string[]]$a)
    $r = & $ctl --pipe $pipeName @a 2>&1
    "CTL $($a -join ' ') => $r (exit $LASTEXITCODE)"
}

Ctl @("list")
Ctl @("open-browser","https://example.com")
Start-Sleep -Seconds 8   # WebView2 init + page load
Ctl @("list")
Ctl @("eval","1","document.title")
Ctl @("eval","1","({u:location.href,n:document.querySelectorAll('p').length})")
Ctl @("navigate","1","https://ghostty.org")
Start-Sleep -Seconds 5
Ctl @("eval","1","document.title")
Ctl @("switch","0")
# Negative path: eval on a terminal tab must answer ok=false (exit 2).
Ctl @("eval","0","1+1")

$p.Refresh()
$h = $p.MainWindowHandle
if ($h -ne 0) {
    $r = New-Object U+R
    [void][U]::GetClientRect($h, [ref]$r)
    $w = $r.rr - $r.l; $ht = $r.b - $r.t
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [U]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($Out); $bmp.Dispose()
    "PrintWindow=$ok $w x $ht -> $Out"
}

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
exit 0
