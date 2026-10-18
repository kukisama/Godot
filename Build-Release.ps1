[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$inn = Join-Path $root 'StarlightInn'
$localEngine = Join-Path $inn 'tools\godot-standard\Godot_v4.7.2-stable_win64_console.exe'
$engineCommand = Get-Command godot_console.exe -ErrorAction SilentlyContinue
$engine = if (Test-Path -LiteralPath $localEngine -PathType Leaf) {
    $localEngine
} elseif ($engineCommand) {
    $engineCommand.Source
} else {
    $null
}
$qa = Join-Path $root 'qa\release'
if (-not $engine) {
    throw 'Godot 4.7.2 is required. Run Initialize-Windows.ps1 first.'
}
$engineVersion = (& $engine --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $engineVersion.StartsWith('4.7.2.stable.')) {
    throw "Godot 4.7.2 is required; found: $engineVersion"
}

$localTemplates = Join-Path $inn 'tools\godot-standard\templates'
$userTemplates = Join-Path $env:APPDATA 'Godot\export_templates\4.7.2.stable'
if ((Test-Path -LiteralPath (Join-Path $localTemplates 'windows_release_x86_64.exe') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $userTemplates 'windows_release_x86_64.exe') -PathType Leaf)) {
    New-Item -ItemType Directory -Path $userTemplates -Force | Out-Null
    foreach ($templateFile in @('windows_release_x86_64.exe', 'windows_debug_x86_64.exe', 'version.txt')) {
        $src = Join-Path $localTemplates $templateFile
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $userTemplates $templateFile) -Force
        }
    }
}

New-Item -ItemType Directory -Path $qa -Force | Out-Null

& (Join-Path $inn 'native\build.ps1')
$helper = Join-Path $inn 'qa\native-build\StarlightAzure.exe'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw 'Native build did not produce StarlightAzure.exe.'
}

function Invoke-Godot([string]$StepName, [string[]]$Arguments, [string]$LogPath) {
    $psi = [Diagnostics.ProcessStartInfo]::new($engine)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $root
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }
    $proc = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $output = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($LogPath, $output, [Text.UTF8Encoding]::new($false))
    if ($proc.ExitCode -ne 0 -or $output -match '(?m)^(?:SCRIPT ERROR|ERROR):') {
        throw "$StepName failed (exit=$($proc.ExitCode)). See $LogPath"
    }
}

$outputs = @()
foreach ($name in @('ForestGlow', 'HollowBell', 'StarlightInn')) {
    $project = Join-Path $root $name
    $play = Join-Path $project 'play'
    New-Item -ItemType Directory -Path $play -Force | Out-Null
    $exe = Join-Path $play ($name + '.exe')
    $importLog = Join-Path $qa ($name + '-import.log')
    Invoke-Godot "Resource import ($name)" @('--headless', '--language', 'en', '--editor', '--path', $project, '--import') $importLog
    $exportLog = Join-Path $qa ($name + '-export.log')
    Invoke-Godot "Release export ($name)" @('--headless', '--language', 'en', '--path', $project, '--export-release', 'Windows Desktop', $exe) $exportLog
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Missing release executable: $name"
    }
    $outputs += $play
    Write-Output "RELEASE_EXPORT_OK $name -> $exe"
}

$hollowLauncher = Join-Path $root 'HollowBell\play\Start-HollowBell.cmd'
$launcherContent = @"
@echo off
setlocal
if not exist "%~dp0HollowBell.exe" (
    echo HollowBell.exe is missing. Export the HollowBell Windows Desktop preset first.
    exit /b 1
)
start "" "%~dp0HollowBell.exe" --rendering-driver opengl3_angle
"@
Set-Content -LiteralPath $hollowLauncher -Value $launcherContent -Encoding ASCII

$innPlay = Join-Path $inn 'play'
$native = Join-Path $innPlay 'native'
New-Item -ItemType Directory -Path $native -Force | Out-Null
Copy-Item -LiteralPath $helper -Destination (Join-Path $native 'StarlightAzure.exe') -Force
Copy-Item -LiteralPath $helper -Destination (Join-Path $inn 'native\StarlightAzure.exe') -Force
foreach ($doc in @('README.md', 'API.md', 'AAD_SETUP.md')) {
    Copy-Item -LiteralPath (Join-Path $inn $doc) -Destination (Join-Path $innPlay $doc) -Force
}
$config = Join-Path $innPlay 'azure-settings.json'
if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath (Join-Path $inn 'azure-settings.json') -Destination $config
}
if ((Get-FileHash -LiteralPath $helper).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $native 'StarlightAzure.exe')).Hash) {
    throw 'Packaged native helper differs from the current build.'
}
Compress-Archive -Path $innPlay -DestinationPath (Join-Path $inn 'StarlightInn-Windows.zip') -Force
Write-Output 'RELEASE_DELIVERY_OK: three games exported to their respective project play directories; existing player configuration preserved.'
foreach ($dir in $outputs) {
    Get-ChildItem -LiteralPath $dir -Recurse -File | Select-Object FullName, Length, LastWriteTime
}
