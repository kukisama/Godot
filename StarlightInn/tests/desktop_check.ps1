param(
    [Parameter(Mandatory)][int]$ProcessId,
    [ValidateSet('Capture', 'Click', 'Key', 'KeyDown', 'KeyUp', 'Text', 'Close')][string]$Action = 'Capture',
    [ValidateSet('Foreground', 'WindowMessage')][string]$Delivery = 'Foreground',
    [double]$X,
    [double]$Y,
    [int]$VirtualKey,
    [string]$Text,
    [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('StarlightNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StarlightNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort vk, scan; public uint flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT key;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION data; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public static void Key(ushort vk, bool down) {
        INPUT input = new INPUT(); input.type = 1; input.data.key.vk = vk;
        input.data.key.flags = down ? 0u : 2u;
        if (SendInput(1, new INPUT[] { input }, Marshal.SizeOf<INPUT>()) != 1)
            throw new InvalidOperationException("Native key input rejected: " + Marshal.GetLastWin32Error());
    }
    public static void Unicode(string text) {
        foreach (char c in text) {
            INPUT down = new INPUT(); down.type = 1; down.data.key.scan = c; down.data.key.flags = 4;
            INPUT up = down; up.data.key.flags = 6;
            if (SendInput(2, new INPUT[] { down, up }, Marshal.SizeOf<INPUT>()) != 2)
                throw new InvalidOperationException("Native Unicode input rejected.");
        }
    }
}
'@
}

[void][StarlightNative]::SetProcessDPIAware()
$process = Get-Process -Id $ProcessId
$expected = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\play\StarlightInn.exe'))
if (-not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to operate on any process other than this project export.'
}
$window = $process.MainWindowHandle
if ($window -eq [IntPtr]::Zero) { throw 'Game window is not ready.' }
if ($Action -eq 'Close') {
    if (-not $process.CloseMainWindow()) { throw 'Could not close the game normally.' }
    if (-not $process.WaitForExit(10000)) { throw 'The game did not exit normally.' }
    "CLOSED process=$ProcessId exit=$($process.ExitCode)"
    return
}

if ($Delivery -eq 'Foreground') {
    [void][StarlightNative]::SetForegroundWindow($window)
    if ([StarlightNative]::GetForegroundWindow() -ne $window) { throw 'Could not foreground the verified game window.' }
}
$rect = [StarlightNative+RECT]::new()
$origin = [StarlightNative+POINT]::new()
if (-not [StarlightNative]::GetClientRect($window, [ref]$rect)) { throw 'GetClientRect failed.' }
if (-not [StarlightNative]::ClientToScreen($window, [ref]$origin)) { throw 'ClientToScreen failed.' }
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
$scale = [Math]::Min($width / 1600.0, $height / 1000.0)
$offsetX = ($width - 1600 * $scale) / 2
$offsetY = ($height - 1000 * $scale) / 2

if ($Action -eq 'Click') {
    if ($X -lt 0 -or $X -gt 1600 -or $Y -lt 0 -or $Y -gt 1000) { throw 'Click outside logical viewport.' }
    if ($Delivery -eq 'WindowMessage') {
        $point = [IntPtr](([int]($offsetX + $X * $scale) -band 0xffff) -bor ([int]($offsetY + $Y * $scale) -shl 16))
        if (-not [StarlightNative]::PostMessage($window,0x0200,[IntPtr]::Zero,$point)) { throw 'Mouse move rejected.' }
        if (-not [StarlightNative]::PostMessage($window,0x0201,[IntPtr]1,$point)) { throw 'Mouse down rejected.' }
        if (-not [StarlightNative]::PostMessage($window,0x0202,[IntPtr]::Zero,$point)) { throw 'Mouse up rejected.' }
    }
    else {
        if (-not [StarlightNative]::SetCursorPos($origin.X + [int]($offsetX + $X * $scale), $origin.Y + [int]($offsetY + $Y * $scale))) { throw 'SetCursorPos failed.' }
        [StarlightNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [StarlightNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
}
elseif ($Action -in @('Key', 'KeyDown', 'KeyUp')) {
    if ($VirtualKey -lt 1 -or $VirtualKey -gt 254) { throw 'Invalid virtual key.' }
    if ($Delivery -eq 'WindowMessage') {
        $scan = [StarlightNative]::MapVirtualKey([uint32]$VirtualKey,0)
        $down = [IntPtr](1 -bor ([int]$scan -shl 16))
        $up = [IntPtr]([int64]$down.ToInt64() -bor 0xc0000000L)
        if ($Action -ne 'KeyUp' -and -not [StarlightNative]::PostMessage($window,0x0100,[IntPtr]$VirtualKey,$down)) { throw 'Key down rejected.' }
        if ($Action -ne 'KeyDown' -and -not [StarlightNative]::PostMessage($window,0x0101,[IntPtr]$VirtualKey,$up)) { throw 'Key up rejected.' }
    }
    else {
        if ($Action -ne 'KeyUp') { [StarlightNative]::Key([ushort]$VirtualKey, $true) }
        if ($Action -ne 'KeyDown') { [StarlightNative]::Key([ushort]$VirtualKey, $false) }
    }
}
elseif ($Action -eq 'Text') {
    if ($Delivery -eq 'WindowMessage') {
        foreach ($character in $Text.ToCharArray()) {
            if (-not [StarlightNative]::PostMessage($window,0x0102,[IntPtr][int]$character,[IntPtr]1)) { throw 'Unicode message rejected.' }
        }
    }
    else { [StarlightNative]::Unicode($Text) }
}

if ($Screenshot) {
    if ($Delivery -ne 'Foreground') { throw 'Screen-copy screenshots require an actual foreground window; use opt-in F12 rendered capture for WindowMessage delivery.' }
    $destination = [IO.Path]::GetFullPath($Screenshot)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, [Drawing.Size]::new($width, $height))
        $bitmap.Save($destination, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
    "CAPTURED $destination ${width}x${height}"
}

[pscustomobject]@{ ProcessId = $process.Id; Responding = $process.Responding; Action = $Action; Delivery = $Delivery; ClientWidth = $width; ClientHeight = $height }