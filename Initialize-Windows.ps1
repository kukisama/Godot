#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$godotVersion = '4.7.2'
$godotTag = "$godotVersion-stable"
$tools = Join-Path $root 'StarlightInn\tools\godot-standard'
$downloads = Join-Path $tools 'downloads'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'This repository requires 64-bit Windows.'
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget is required. Install or update App Installer from Microsoft Store.'
}

Write-Host '1/7 Install Git'
winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
if ($LASTEXITCODE -ne 0) { throw 'Git installation failed.' }

Write-Host '2/7 Install Visual Studio Code'
winget install --id Microsoft.VisualStudioCode --exact --source winget --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio Code installation failed.' }

Write-Host '3/7 Install Godot Engine'
winget install --id GodotEngine.GodotEngine --exact --version $godotVersion --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
if ($LASTEXITCODE -ne 0) { throw 'Godot installation failed.' }

Write-Host '4/7 Install .NET 8 SDK'
winget install --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
if ($LASTEXITCODE -ne 0) { throw '.NET 8 SDK installation failed.' }

Write-Host '5/7 Install Visual Studio C++ Build Tools and Windows SDK'
Write-Host 'Approve the Windows administrator prompt when it appears.'
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --accept-package-agreements --accept-source-agreements --override '--passive --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
if ($LASTEXITCODE -ne 0) { throw 'Visual Studio C++ Build Tools installation failed.' }

Write-Host '6/7 Install Godot export templates'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
$releaseUrl = "https://github.com/godotengine/godot/releases/download/$godotTag"
$sums = Join-Path $downloads 'SHA512-SUMS.txt'
$packageName = "Godot_v$godotVersion-stable_export_templates.tpz"
$package = Join-Path $downloads $packageName
curl.exe --fail --location --retry 3 --output $sums "$releaseUrl/SHA512-SUMS.txt"
if ($LASTEXITCODE -ne 0) { throw 'Godot checksum download failed.' }
curl.exe --fail --location --retry 3 --output $package "$releaseUrl/$packageName"
if ($LASTEXITCODE -ne 0) { throw 'Godot export template download failed.' }
$sumLine = Get-Content -LiteralPath $sums | Where-Object { $_ -match ([regex]::Escape($packageName) + '$') }
if (@($sumLine).Count -ne 1) { throw 'Official Godot checksum was not found.' }
$expected = ($sumLine -split '\s+')[0]
if ((Get-FileHash -LiteralPath $package -Algorithm SHA512).Hash -ne $expected) {
    throw 'Godot export template checksum mismatch.'
}
$extract = Join-Path $downloads 'templates-extracted'
if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
New-Item -ItemType Directory -Path $extract -Force | Out-Null
tar.exe -xf $package -C $extract
if ($LASTEXITCODE -ne 0) { throw 'Godot export template extraction failed.' }
$source = Join-Path $extract 'templates'
$templateVersion = (Get-Content -LiteralPath (Join-Path $source 'version.txt') -Raw).Trim()
$userTemplates = Join-Path $env:APPDATA "Godot\export_templates\$templateVersion"
$projectTemplates = Join-Path $tools 'templates'
New-Item -ItemType Directory -Path $projectTemplates, $userTemplates -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'windows_release_x86_64.exe') -Destination $projectTemplates -Force
Copy-Item -LiteralPath (Join-Path $source 'windows_debug_x86_64.exe') -Destination $projectTemplates -Force
Copy-Item -LiteralPath (Join-Path $source 'version.txt') -Destination $projectTemplates -Force
Copy-Item -Path (Join-Path $source '*') -Destination $userTemplates -Recurse -Force
Remove-Item -LiteralPath $extract -Recurse -Force

Write-Host '7/7 Install VS Code extensions'
$code = Get-Command code.cmd -ErrorAction SilentlyContinue
if (-not $code) { $code = Get-Command code.exe -ErrorAction SilentlyContinue }
$codePath = if ($code) { $code.Source } else {
    Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
}
if (-not (Test-Path -LiteralPath $codePath -PathType Leaf)) {
    throw 'VS Code was installed, but code.cmd was not found.'
}
& $codePath --install-extension geequlim.godot-tools --force
if ($LASTEXITCODE -ne 0) { throw 'Godot Tools extension installation failed.' }
& $codePath --install-extension ms-dotnettools.csharp --force
if ($LASTEXITCODE -ne 0) { throw 'C# extension installation failed.' }

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vc = if (Test-Path -LiteralPath $vswhere) {
    & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vc) { throw 'Visual Studio C++ toolchain was not found after installation.' }
if (-not (Get-Command godot_console.exe -ErrorAction SilentlyContinue)) {
    Write-Warning 'Godot was installed, but this terminal has not received the updated PATH. Restart the terminal before building.'
}

Write-Host ''
Write-Host 'Initialization completed.'
Write-Host 'Restart VS Code, then run:'
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Release.ps1'
