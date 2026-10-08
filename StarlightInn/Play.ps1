$ErrorActionPreference = 'Stop'
$executable = Join-Path $PSScriptRoot 'play\StarlightInn.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'Missing play\StarlightInn.exe. Export the Windows Desktop preset first.'
}
# This version is intentionally silent. No services or credentials are needed.
Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) -ArgumentList @('--rendering-driver', 'opengl3_angle', '--audio-driver', 'Dummy')