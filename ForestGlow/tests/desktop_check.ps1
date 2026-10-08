param(
    [Parameter(Mandatory)][int]$ProcessId,
    [ValidateSet('Capture', 'PlayAndPause', 'Menu', 'Close')][string]$Action = 'Capture',
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('ForestGlowNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ForestGlowNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
}

[void][ForestGlowNative]::SetProcessDPIAware()
$process = Get-Process -Id $ProcessId
$expected = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\play\ForestGlow.exe'))
if ($process.Path -ne $expected) { throw 'Refusing to operate on an unrelated process.' }
$window = $process.MainWindowHandle
if ($window -eq [IntPtr]::Zero) { throw 'Game window is not ready.' }

if ($Action -eq 'Close') {
    if (-not $process.CloseMainWindow()) { throw 'Could not close game normally.' }
    if (-not $process.WaitForExit(10000)) { throw 'Game did not exit normally.' }
    "CLOSED process=$ProcessId exit=$($process.ExitCode)"
    return
}

[void][ForestGlowNative]::SetForegroundWindow($window)
if ([ForestGlowNative]::GetForegroundWindow() -ne $window) { throw 'Could not foreground the game.' }
$rect = [ForestGlowNative+RECT]::new()
$origin = [ForestGlowNative+POINT]::new()
if (-not [ForestGlowNative]::GetClientRect($window, [ref]$rect)) { throw 'GetClientRect failed.' }
if (-not [ForestGlowNative]::ClientToScreen($window, [ref]$origin)) { throw 'ClientToScreen failed.' }
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
$scale = [Math]::Min($width / 1280.0, $height / 800.0)
$offsetX = ($width - 1280 * $scale) / 2
$offsetY = ($height - 800 * $scale) / 2

function Invoke-GameClick([double]$X, [double]$Y) {
    $screenX = $origin.X + [int]($offsetX + $X * $scale)
    $screenY = $origin.Y + [int]($offsetY + $Y * $scale)
    if (-not [ForestGlowNative]::SetCursorPos($screenX, $screenY)) { throw 'SetCursorPos failed.' }
    [ForestGlowNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [ForestGlowNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

if ($Action -eq 'PlayAndPause') {
    Invoke-GameClick 640 548
    Invoke-GameClick 492 331
    Invoke-GameClick 800 530
    Invoke-GameClick 1038 68
    'SENT_NATIVE_MOUSE: start, amber, blue, pause'
}
elseif ($Action -eq 'Menu') {
    Invoke-GameClick 640 617
    'SENT_NATIVE_MOUSE: return to menu'
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
    "CAPTURED $destination ${width}x${height}"
}

[pscustomobject]@{ ProcessId = $process.Id; Responding = $process.Responding; Window = $window; ClientWidth = $width; ClientHeight = $height }