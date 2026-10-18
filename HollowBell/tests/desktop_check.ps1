param(
    [Parameter(Mandatory)][int]$ProcessId,
    [ValidateSet('Capture', 'Click', 'KeyDown', 'KeyUp', 'Tap', 'Close')][string]$Action = 'Capture',
    [ValidateSet('Left', 'Right', 'Jump', 'Attack', 'Heavy', 'Dodge', 'QuickRoll', 'Guard', 'Heal', 'Escape', 'Enter', 'Fullscreen')][string]$Key = 'Enter',
    [double]$X = 0,
    [double]$Y = 0,
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('HollowBellNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HollowBellNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
'@
}

[void][HollowBellNative]::SetProcessDPIAware()
$process = Get-Process -Id $ProcessId
$expected = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\play\HollowBell.exe'))
if (-not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to control a process outside the expected delivery: $expected"
}
$window = $process.MainWindowHandle
if ($window -eq [IntPtr]::Zero) { throw 'Game window is not ready.' }

if ($Action -eq 'Close') {
    if (-not $process.CloseMainWindow()) { throw 'Could not close the game normally.' }
    if (-not $process.WaitForExit(10000)) { throw 'Game did not exit normally.' }
    "NATIVE_CLOSE process=$ProcessId exit=$($process.ExitCode)"
    return
}

[void][HollowBellNative]::SetForegroundWindow($window)
if ([HollowBellNative]::GetForegroundWindow() -ne $window) { throw 'Game does not own input focus.' }
$rect = [HollowBellNative+RECT]::new()
$origin = [HollowBellNative+POINT]::new()
if (-not [HollowBellNative]::GetClientRect($window, [ref]$rect)) { throw 'GetClientRect failed.' }
if (-not [HollowBellNative]::ClientToScreen($window, [ref]$origin)) { throw 'ClientToScreen failed.' }
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
$keys = @{ Left = 0x41; Right = 0x44; Jump = 0x20; Attack = 0x4A; Heavy = 0x4B; Dodge = 0x10; QuickRoll = 0x43; Guard = 0x51; Heal = 0x45; Escape = 0x1B; Enter = 0x0D; Fullscreen = 0x7A }

if ($Action -in @('KeyDown', 'Tap')) { [HollowBellNative]::keybd_event([byte]$keys[$Key], 0, 0, [UIntPtr]::Zero) }
if ($Action -in @('KeyUp', 'Tap')) { [HollowBellNative]::keybd_event([byte]$keys[$Key], 0, 2, [UIntPtr]::Zero) }
if ($Action -eq 'Click') {
    $scale = [Math]::Min($width / 1440.0, $height / 810.0)
    $screenX = $origin.X + [int](($width - 1440 * $scale) / 2 + $X * $scale)
    $screenY = $origin.Y + [int](($height - 810 * $scale) / 2 + $Y * $scale)
    if (-not [HollowBellNative]::SetCursorPos($screenX, $screenY)) { throw 'Could not set the pointer.' }
    [HollowBellNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [HollowBellNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}
if ($Screenshot) {
    $destination = [IO.Path]::GetFullPath($Screenshot)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, [Drawing.Size]::new($width, $height))
        $bitmap.Save($destination, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
[pscustomobject]@{ ProcessId = $process.Id; StartedUTC = $process.StartTime.ToUniversalTime().ToString('O'); Responding = $process.Responding; Action = $Action; Key = $Key; Client = "${width}x${height}"; Screenshot = $Screenshot }