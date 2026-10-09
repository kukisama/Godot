[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'qa\native-build'
New-Item -ItemType Directory -Path $out -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $out '.gdignore') -Force | Out-Null
$vc = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path -LiteralPath $vc)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installation = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $vc = Join-Path $installation 'VC\Auxiliary\Build\vcvarsall.bat'
        }
    }
}
if (-not (Test-Path -LiteralPath $vc)) { throw 'Existing VS2022 x64 Build Tools required; no installation/configuration performed.' }
$envLines = & cmd.exe /d /c "call `"$vc`" amd64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'vcvarsall failed' }
# Child compiler environment only; do not modify user or machine configuration.
$compilerEnv = @{}
foreach ($line in $envLines) { if ($line -match '^([^=]+)=(.*)$') { $compilerEnv[$matches[1]] = $matches[2] } }
function Compile([string]$name, [string[]]$sources, [string[]]$extra) {
    $start = [Diagnostics.ProcessStartInfo]::new('cl.exe')
    $start.FileName = Join-Path ($compilerEnv.Path -split ';' | Where-Object { Test-Path (Join-Path $_ 'cl.exe') } | Select-Object -First 1) 'cl.exe'
    $start.UseShellExecute = $false; $start.WorkingDirectory = $out
    foreach ($key in $compilerEnv.Keys) { $start.Environment[$key] = $compilerEnv[$key] }
    foreach ($arg in @('/nologo','/std:c++20','/EHsc','/MT','/O1','/W4','/WX','/utf-8','/DUNICODE','/D_UNICODE','/DWIN32_LEAN_AND_MEAN',('/I'+$PSScriptRoot),('/Fe:'+ (Join-Path $out $name))) + $extra + $sources + @('/link','/INCREMENTAL:NO','/OPT:REF','/OPT:ICF','windowsapp.lib','winhttp.lib','crypt32.lib','bcrypt.lib','shell32.lib','ole32.lib','user32.lib')) { $start.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::Start($start); $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Native build failed: $name ($($p.ExitCode))" }
}
$shared = @('common.cpp','profile.cpp','core.cpp','identity.cpp','http.cpp') | ForEach-Object { Join-Path $PSScriptRoot $_ }
Compile 'StarlightAzure.exe' ($shared + (Join-Path $PSScriptRoot 'protocol.cpp')) @()
Compile 'native-tests.exe' ($shared + (Join-Path $root 'tests\native_tests.cpp')) @()
Compile 'pipe-fixture.exe' ($shared + (Join-Path $PSScriptRoot 'protocol.cpp')) @('/DINN_FIXTURE')
Compile 'wam-probe.exe' ($shared + (Join-Path $root 'tests\wam_probe.cpp')) @()
Write-Output 'NATIVE_BUILD_OK: /MT /W4 /WX; production, shared-core tests, separate pipe fixture, non-auth discovery probe'