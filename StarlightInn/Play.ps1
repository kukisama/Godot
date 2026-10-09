$ErrorActionPreference = 'Stop'
$executable = Join-Path $PSScriptRoot 'play\StarlightInn.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'Missing play\StarlightInn.exe. Export the Windows Desktop preset first.'
}
# Sound is enabled by default. Offline play needs no login; optional delegated
# Azure configuration is read beside the EXE. Copy the entire play directory.
Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) -ArgumentList @('--rendering-driver', 'opengl3_angle')