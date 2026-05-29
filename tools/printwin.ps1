param([string]$ProcName="ghostty",[string]$Out="E:\ghosttty\.pw.png")
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class PW{
 [DllImport("user32.dll")]public static extern bool GetClientRect(IntPtr h,out R r);
 [DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr hdc,uint flags);
 [DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
 public struct R{public int l,t,rr,b;}
}
"@
# Opt this PowerShell process into per-monitor DPI awareness so
# GetClientRect / PrintWindow return values at the window's actual
# pixel resolution instead of the virtualized (downscaled) one.
# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
[void][PW]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
$p=Get-Process -Name $ProcName -ErrorAction SilentlyContinue|?{$_.MainWindowHandle -ne 0}|select -First 1
if(-not $p){"NO_WINDOW";exit 1}
$h=$p.MainWindowHandle
$r=New-Object PW+R;[void][PW]::GetClientRect($h,[ref]$r)
$w=$r.rr-$r.l;$ht=$r.b-$r.t
if($w -le 0){"BAD_RECT";exit 1}
$bmp=New-Object System.Drawing.Bitmap $w,$ht
$g=[System.Drawing.Graphics]::FromImage($bmp)
$hdc=$g.GetHdc()
# PW_RENDERFULLCONTENT = 2
$ok=[PW]::PrintWindow($h,$hdc,2)
$g.ReleaseHdc($hdc);$g.Dispose()
$bmp.Save($Out);$bmp.Dispose()
"PrintWindow=$ok $w x $ht -> $Out"
