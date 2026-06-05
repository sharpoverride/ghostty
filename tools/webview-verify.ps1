param([string]$Out="E:\ghosttty\tools\webview-verify.png")
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;using System.Runtime.InteropServices;
public class U{
 [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out R r);
 [DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
 [DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte scan,uint flags,IntPtr extra);
 [DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]public static extern void mouse_event(uint f,uint dx,uint dy,uint d,IntPtr e);
 public struct R{public int l,t,rr,b;}
 public static void ClickAt(int x,int y){
   SetCursorPos(x,y);
   System.Threading.Thread.Sleep(80);
   mouse_event(0x0002,0,0,0,IntPtr.Zero); // LEFTDOWN
   mouse_event(0x0004,0,0,0,IntPtr.Zero); // LEFTUP
 }
 // Real Ctrl+Shift+B via keybd_event so GetKeyState() sees the modifiers
 // (SendKeys doesn't reliably set them for control combos).
 public static void CtrlShiftB(){
   const uint UP=2;
   keybd_event(0x11,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(60); // Ctrl down
   keybd_event(0x10,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(60); // Shift down
   keybd_event(0x42,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(60); // B down
   keybd_event(0x42,0,UP,IntPtr.Zero);System.Threading.Thread.Sleep(20);
   keybd_event(0x10,0,UP,IntPtr.Zero);System.Threading.Thread.Sleep(20);
   keybd_event(0x11,0,UP,IntPtr.Zero);
 }
}
"@
[void][U]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$log = "E:\ghosttty\tools\webview-run.log"
if (Test-Path $log) { Remove-Item $log }

# Auto-open the browser pane at startup (deterministic test hook).
$env:GHOSTTY_OPEN_BROWSER = "1"

# Launch ghostty with stderr captured (console subsystem → std.log goes there).
$p = Start-Process -FilePath "E:\ghosttty\zig-out\bin\ghostty.exe" `
    -RedirectStandardError $log -RedirectStandardOutput "E:\ghosttty\tools\webview-run.out" `
    -PassThru
Start-Sleep -Seconds 5   # window + shell come up

# Find the main window and bring it forward.
$p.Refresh()
$h = $p.MainWindowHandle
if ($h -eq 0) {
    $g = Get-Process -Name ghostty -ErrorAction SilentlyContinue | ?{ $_.MainWindowHandle -ne 0 } | select -First 1
    if ($g) { $h = $g.MainWindowHandle }
}
if ($h -eq 0) { "NO_WINDOW"; exit 1 }
[void][U]::ShowWindow($h, 3)            # SW_MAXIMIZE (deterministic geometry)
[void][U]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 800

Start-Sleep -Seconds 7                  # WebView2 first-run init can be slow

function Capture($path){
    $r = New-Object U+R
    [void][U]::GetWindowRect($h, [ref]$r)
    $w = $r.rr - $r.l; $ht = $r.b - $r.t
    if ($w -le 0 -or $ht -le 0) { "BAD_RECT $w x $ht"; return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $g2.CopyFromScreen($r.l, $r.t, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
    $g2.Dispose(); $bmp.Save($path); $bmp.Dispose()
    "CAPTURED $w x $ht -> $path"
    return $r
}

# Shot 1: browser tab active (opened by the startup hook).
$r = Capture $Out

# Click the FIRST tab pill (PowerShell) in the sidebar to switch back to the
# terminal, proving the browser is a real, switchable tab.
if ($r) {
    $w = $r.rr - $r.l; $ht = $r.b - $r.t
    [U]::ClickAt([int]($r.l + $w*0.05), [int]($r.t + $ht*0.115))
    Start-Sleep -Milliseconds 700
    $out2 = [System.IO.Path]::ChangeExtension($Out, $null) + "-tab1.png"
    Capture $out2 | Out-Null
    "SHOT2 -> $out2"
}

"--- log (webview lines) ---"
if (Test-Path $log) { Select-String -Path $log -Pattern "webview|WebView2|openBrowser" }

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
