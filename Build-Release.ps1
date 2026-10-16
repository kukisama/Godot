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
$play = Join-Path $root 'play'
$qa = Join-Path $root 'qa\release'
if (-not $engine) {
    throw 'Godot 4.7.2 is required. Run Initialize-Windows.ps1 first.'
}
$engineVersion = (& $engine --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $engineVersion.StartsWith('4.7.2.stable.')) {
    throw "Godot 4.7.2 is required; found: $engineVersion"
}
New-Item -ItemType Directory -Path $play, $qa -Force | Out-Null

& (Join-Path $inn 'native\build.ps1')
$helper = Join-Path $inn 'qa\native-build\StarlightAzure.exe'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw 'Native build did not produce StarlightAzure.exe.'
}

foreach ($name in @('ForestGlow', 'HollowBell', 'StarlightInn')) {
    $project = Join-Path $root $name
    $exe = Join-Path $play ($name + '.exe')
    $importLog = Join-Path $qa ($name + '-import.log')
    & $engine --headless --language en --editor --path $project --import 2>&1 |
        Tee-Object -FilePath $importLog
    if ($LASTEXITCODE -ne 0 -or
        (Select-String -LiteralPath $importLog -Pattern '^SCRIPT ERROR:|^ERROR:' -Quiet)) {
        throw "Resource import failed: $name. See $importLog"
    }
    $exportLog = Join-Path $qa ($name + '-export.log')
    & $engine --headless --language en --path $project --export-release 'Windows Desktop' $exe 2>&1 |
        Tee-Object -FilePath $exportLog
    if ($LASTEXITCODE -ne 0 -or
        (Select-String -LiteralPath $exportLog -Pattern '^SCRIPT ERROR:|^ERROR:' -Quiet)) {
        throw "Release export failed: $name. See $exportLog"
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Missing release executable: $name"
    }
    Write-Output "RELEASE_EXPORT_OK $name"
}

$native = Join-Path $play 'native'
New-Item -ItemType Directory -Path $native -Force | Out-Null
Copy-Item -LiteralPath $helper -Destination (Join-Path $native 'StarlightAzure.exe') -Force
Copy-Item -LiteralPath $helper -Destination (Join-Path $inn 'native\StarlightAzure.exe') -Force
foreach ($doc in @('README.md', 'API.md', 'AAD_SETUP.md')) {
    Copy-Item -LiteralPath (Join-Path $inn $doc) -Destination (Join-Path $play $doc) -Force
}
$config = Join-Path $play 'azure-settings.json'
if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath (Join-Path $inn 'azure-settings.json') -Destination $config
}
if ((Get-FileHash -LiteralPath $helper).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $native 'StarlightAzure.exe')).Hash) {
    throw 'Packaged native helper differs from the current build.'
}
Write-Output 'RELEASE_DELIVERY_OK: three games and the required native helper; existing player configuration preserved.'
Get-ChildItem -LiteralPath $play -Recurse -File | Select-Object FullName, Length, LastWriteTime
