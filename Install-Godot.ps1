#requires -Version 5.1
<#
Install the official Windows x64 Godot .NET editor and export templates.
Run: powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Godot.ps1
#>
[CmdletBinding()]
param(
    [ValidatePattern('^4\.\d+\.\d+$')]
    [string]$Version = '4.7.2',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Godot'),
    [switch]$SkipTemplates,
    [switch]$SkipExtensions,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::Is64BitOperatingSystem -eq $false -or
    $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
    throw 'This script requires Windows x64 (not ARM64).'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8 = New-Object Text.UTF8Encoding($false)
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$cache = Join-Path $InstallRoot 'downloads'
$bin = Join-Path $InstallRoot 'bin'
$tag = "$Version-stable"
$baseUrl = "https://github.com/godotengine/godot/releases/download/$tag"
$editorName = "Godot_v${Version}-stable_mono_win64"
$editorDir = Join-Path $InstallRoot $editorName
$editor = Join-Path $editorDir "$editorName.exe"
$console = Join-Path $editorDir "${editorName}_console.exe"
$templateDir = Join-Path $env:APPDATA "Godot\export_templates\$Version.stable.mono"
New-Item -ItemType Directory -Path $InstallRoot,$cache,$bin -Force | Out-Null
$log = Join-Path $InstallRoot ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
Start-Transcript -Path $log | Out-Null

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE)." }
}

function Get-VerifiedArchive {
    param([string]$Name)
    $lines = @($script:sums -split "`n" | Where-Object {
        $_.Trim() -match ('^[a-fA-F0-9]{128}\s+\*?' + [regex]::Escape($Name) + '$')
    })
    if ($lines.Count -ne 1) { throw "No unique official SHA512 checksum for $Name." }
    $expected = ($lines[0].Trim() -split '\s+')[0]
    $path = Join-Path $cache $Name
    if ((Test-Path -LiteralPath $path) -and
        (Get-FileHash -LiteralPath $path -Algorithm SHA512).Hash -eq $expected) {
        Write-Host "Verified cached download: $Name"
        return $path
    }
    $part = "$path.part"
    Write-Host "Downloading: $baseUrl/$Name"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        try {
            Invoke-Checked 'curl.exe' @('--fail','--location','--retry','3','--retry-all-errors',
                '--connect-timeout','30','--output',$part,"$baseUrl/$Name")
        } catch {
            $mirror = "https://godot-releases.nbg1.your-objectstorage.com/$tag/$Name"
            Write-Warning "GitHub download failed; trying the official Godot mirror: $mirror"
            Invoke-Checked 'curl.exe' @('--fail','--location','--retry','3','--retry-all-errors',
                '--connect-timeout','30','--output',$part,$mirror)
        }
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$Name" -OutFile $part
    }
    $actual = (Get-FileHash -LiteralPath $part -Algorithm SHA512).Hash
    if ($actual -ne $expected) { throw "SHA512 mismatch for $Name. The archive will not be extracted." }
    Move-Item -LiteralPath $part -Destination $path -Force
    Write-Host "SHA512 OK: $Name"
    return $path
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}

try {
    # Existing SDKs and editors are reused; no system execution-policy changes.
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'Install the x64 .NET 8+ SDK first: winget install --id Microsoft.DotNet.SDK.8 --exact --source winget'
    }
    $sdks = @(& dotnet --list-sdks)
    if ($LASTEXITCODE -ne 0 -or -not ($sdks | Where-Object { $_ -match '^(8|9|[1-9]\d)\.\d+\.\d+\s' })) {
        throw 'A stable .NET 8+ SDK is required; a runtime or preview SDK alone is not sufficient.'
    }
    $runtimes = @(& dotnet --list-runtimes)
    if ($LASTEXITCODE -ne 0 -or -not ($runtimes | Where-Object { $_ -match '^Microsoft.NETCore.App 8\.' })) {
        throw 'The net8.0 validation project needs .NET 8 runtime: winget install --id Microsoft.DotNet.Runtime.8 --exact --source winget'
    }
    $sdks | ForEach-Object { Write-Host "SDK: $_" }
    $sumResponse = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA512-SUMS.txt"
    $script:sums = if ($sumResponse.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($sumResponse.Content)
    } else { [string]$sumResponse.Content }
    Write-Utf8 (Join-Path $cache "$tag-SHA512-SUMS.txt") $script:sums
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $editorArchive = Get-VerifiedArchive "$editorName.zip"
    if (-not (Test-Path -LiteralPath $editor)) {
        $stage = Join-Path $InstallRoot ('stage-' + [guid]::NewGuid().ToString('N'))
        [IO.Compression.ZipFile]::ExtractToDirectory($editorArchive, $stage)
        $source = Join-Path $stage $editorName
        if (-not (Test-Path -LiteralPath (Join-Path $source "$editorName.exe"))) {
            throw "Unexpected editor archive layout: $stage"
        }
        if (Test-Path -LiteralPath $editorDir) { throw "Incomplete installation exists: $editorDir. Move it aside before retrying." }
        Move-Item -LiteralPath $source -Destination $editorDir
        Remove-Item -LiteralPath $stage
    }
    if (-not (Test-Path -LiteralPath $console)) { throw "Console executable missing: $console" }
    $versionOutput = (& $console --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $versionOutput.StartsWith("$Version.stable.mono.")) {
        throw "Unexpected Godot version: $versionOutput"
    }
    Write-Host "Godot: $versionOutput"

    if (-not $SkipTemplates) {
        $templateArchive = Get-VerifiedArchive "Godot_v${Version}-stable_mono_export_templates.tpz"
        $marker = Join-Path $templateDir 'version.txt'
        if (-not (Test-Path -LiteralPath $marker)) {
            $stage = Join-Path $InstallRoot ('templates-' + [guid]::NewGuid().ToString('N'))
            [IO.Compression.ZipFile]::ExtractToDirectory($templateArchive, $stage)
            $source = Join-Path $stage 'templates'
            $sourceVersion = (Get-Content -LiteralPath (Join-Path $source 'version.txt') -Raw).Trim()
            if ($sourceVersion -ne "$Version.stable.mono") { throw "Unexpected export template version: $sourceVersion" }
            if (Test-Path -LiteralPath $templateDir) { throw "Incomplete template directory: $templateDir. Move it aside before retrying." }
            New-Item -ItemType Directory -Path (Split-Path $templateDir -Parent) -Force | Out-Null
            Move-Item -LiteralPath $source -Destination $templateDir
            Remove-Item -LiteralPath $stage
        }
        if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne "$Version.stable.mono") {
            throw 'Installed export templates have the wrong version.'
        }
        Write-Host "Export templates: $templateDir"
    }

    # Keep the official executable and GodotSharp directory together.
    Write-Utf8 (Join-Path $bin 'godot.cmd') "@echo off`r`n`"$console`" %*`r`n"
    [Environment]::SetEnvironmentVariable('GODOT4', $editor, 'User')
    $env:GODOT4 = $editor
    $userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    if (@($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $bin.TrimEnd('\') }).Count -eq 0) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
    }
    if (@($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $bin.TrimEnd('\') }).Count -eq 0) {
        $env:Path += ";$bin"
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcutDirs = @([Environment]::GetFolderPath('Desktop'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Godot'))
    foreach ($directory in $shortcutDirs) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $shortcut = $shell.CreateShortcut((Join-Path $directory 'Godot .NET.lnk'))
        $shortcut.TargetPath = $editor
        $shortcut.Arguments = '--project-manager'
        $shortcut.WorkingDirectory = $editorDir
        $shortcut.IconLocation = "$editor,0"
        $shortcut.Save()
    }
    if (-not $SkipExtensions) {
        if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
            throw 'VS Code CLI was not found. Install VS Code or use -SkipExtensions.'
        }
        foreach ($extension in @('geequlim.godot-tools','ms-dotnettools.csharp')) {
            Invoke-Checked 'code' @('--install-extension',$extension)
        }
    }

    # Test in an isolated folder, never create a game in the script repository.
    $testDir = Join-Path $InstallRoot ('validation-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    Write-Utf8 (Join-Path $testDir 'global.json') '{"sdk":{"version":"8.0.100","rollForward":"latestMajor","allowPrerelease":false}}'
    Write-Utf8 (Join-Path $testDir 'project.godot') @'
config_version=5
[application]
config/name="Godot Environment Validation"
run/main_scene="res://Main.tscn"
[dotnet]
project/assembly_name="EnvironmentCheck"
[rendering]
renderer/rendering_method="gl_compatibility"
'@
    Write-Utf8 (Join-Path $testDir 'Check.gd') @'
extends SceneTree
func _init():
    print("GDSCRIPT_ENVIRONMENT_OK")
    quit(0)
'@
    $gdOutput = (& $console --headless --path $testDir --script Check.gd 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $gdOutput -notmatch 'GDSCRIPT_ENVIRONMENT_OK') { throw "GDScript test failed: $gdOutput" }
    Write-Host 'GDSCRIPT_ENVIRONMENT_OK'
    Write-Utf8 (Join-Path $testDir 'EnvironmentCheck.csproj') @"
<Project Sdk="Godot.NET.Sdk/$Version">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <EnableDynamicLoading>true</EnableDynamicLoading>
  </PropertyGroup>
</Project>
"@
    Write-Utf8 (Join-Path $testDir 'Main.cs') @'
using Godot;
public partial class Main : Node
{
    public override void _Ready()
    {
        GD.Print("CSHARP_ENVIRONMENT_OK");
        GetTree().Quit(0);
    }
}
'@
    Write-Utf8 (Join-Path $testDir 'Main.tscn') @'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://Main.cs" id="1"]
[node name="Main" type="Node"]
script = ExtResource("1")
'@
    Push-Location $testDir
    try {
        # .NET 10 defaults to .slnx, but Godot's exporter requires .sln.
        $solutionArgs = @('new','sln','--name','EnvironmentCheck')
        $sdkVersion = (& dotnet --version | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot select the validation SDK.' }
        if ([int]($sdkVersion.Split('.')[0]) -ge 10) { $solutionArgs += @('--format','sln') }
        Invoke-Checked 'dotnet' $solutionArgs
        Invoke-Checked 'dotnet' @('sln','EnvironmentCheck.sln','add','EnvironmentCheck.csproj')
        Invoke-Checked 'dotnet' @('build','EnvironmentCheck.csproj','--configuration','Debug','--nologo')
    }
    finally { Pop-Location }
    Invoke-Checked $console @('--headless','--path',$testDir,'--import')
    $csOutput = (& $console --headless --path $testDir --quit-after 120 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $csOutput -notmatch 'CSHARP_ENVIRONMENT_OK') { throw "C# runtime test failed: $csOutput" }
    Write-Host 'CSHARP_ENVIRONMENT_OK'

    if (-not $SkipTemplates) {
        Write-Utf8 (Join-Path $testDir 'export_presets.cfg') @'
[preset.0]
name="Windows Desktop"
platform="Windows Desktop"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="Check.gd"
export_path="build/EnvironmentCheck.exe"
[preset.0.options]
binary_format/architecture="x86_64"
binary_format/embed_pck=true
codesign/enable=false
'@
        $build = Join-Path $testDir 'build'
        New-Item -ItemType Directory -Path $build -Force | Out-Null
        Invoke-Checked $console @('--headless','--path',$testDir,'--export-release',
            'Windows Desktop',(Join-Path $build 'EnvironmentCheck.exe'))
        $exportExe = Join-Path $build 'EnvironmentCheck.exe'
        if (-not (Test-Path -LiteralPath $exportExe)) { throw 'Windows export executable is missing.' }
        $stdout = Join-Path $testDir 'export-stdout.log'
        $stderr = Join-Path $testDir 'export-stderr.log'
        $run = Start-Process -FilePath $exportExe -ArgumentList '--headless','--quit-after','120' -WorkingDirectory $build -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($run.ExitCode -ne 0 -or (Get-Content -LiteralPath $stdout -Raw) -notmatch 'CSHARP_ENVIRONMENT_OK') {
            throw "Exported game failed: exit $($run.ExitCode); see $stdout and $stderr"
        }
        Write-Host 'WINDOWS_EXPORT_AND_RUN_OK'
    }
    # Keep validation evidence and downloads for diagnostics and repeat execution.
    Write-Host "Validation evidence: $testDir"
    Write-Host "Installation log: $log"
    Invoke-Checked (Join-Path $bin 'godot.cmd') @('--version')
    if (-not $NoLaunch) {
        $process = Start-Process -FilePath $editor -ArgumentList '--project-manager' -WorkingDirectory $editorDir -PassThru
        Write-Host "Started Godot Project Manager (PID $($process.Id))."
    }
    Write-Host 'Installation and validation completed. Reopen terminals/VS Code to inherit GODOT4 and PATH.'
} finally {
    Stop-Transcript | Out-Null
}