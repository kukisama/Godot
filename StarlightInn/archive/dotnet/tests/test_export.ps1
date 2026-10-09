# Verifies the actual exported EXE, never authenticates or invokes ARM.
[CmdletBinding()]
param([switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$play = Join-Path $root 'play'
$qa = Join-Path $root 'qa'
$exe = Join-Path $play 'StarlightInn.exe'
$data = Join-Path $play 'data_StarlightInn_windows_x86_64'
$configPath = Join-Path $play 'azure-settings.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$keys = @($config.PSObject.Properties.Name | Sort-Object)
if (($keys -join ',') -ne 'client_id,initial_tenant' -or $config.client_id -isnot [string] -or $config.initial_tenant -isnot [string]) {
    throw 'Invalid public configuration schema; existing configuration is never replaced.'
}
$client = [guid]::Empty
$tenant = [guid]::Empty
if (($config.client_id -ne '' -and (-not [guid]::TryParse($config.client_id, [ref]$client) -or $client -eq [guid]::Empty)) -or
    ($config.initial_tenant -ne 'organizations' -and (-not [guid]::TryParse($config.initial_tenant, [ref]$tenant) -or $tenant -eq [guid]::Empty))) {
    throw 'Invalid public ClientId/initial tenant; existing configuration is never replaced.'
}
$emptyTemplate = $config.client_id -eq '' -and $config.initial_tenant -eq 'organizations'
if (-not $StaticOnly -and -not $emptyTemplate) {
    throw 'This release probe requires the untouched EMPTY public config; it never modifies existing configuration.'
}
$dependencies = @('StarlightInn.dll', 'StarlightInn.runtimeconfig.json', 'StarlightInn.deps.json',
    'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'System.Private.CoreLib.dll',
    'Microsoft.Identity.Client.dll', 'Microsoft.Identity.Client.Broker.dll',
    'Microsoft.Identity.Client.NativeInterop.dll', 'msalruntime.dll')
$artifacts = @()
foreach ($relative in @('StarlightInn.exe', 'azure-settings.json', 'AAD_SETUP.md', 'README.md', 'API.md') + @($dependencies | ForEach-Object { 'data_StarlightInn_windows_x86_64/' + $_ })) {
    $file = Get-Item -LiteralPath (Join-Path $play $relative)
    if ($file.Length -le 0) { throw "Empty release artifact: $relative" }
    $artifacts += [ordered]@{ path = $relative; bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
}
foreach ($doc in @('AAD_SETUP.md', 'README.md', 'API.md')) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $doc)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $play $doc)).Hash) { throw "Release doc differs from source: $doc" }
}
if (@(Get-ChildItem -LiteralPath $play -Recurse -File -Filter 'session-profile*').Count) { throw 'Release must not ship remembered account metadata.' }
$unexpected = @(Get-ChildItem -LiteralPath $play -Recurse -File | Where-Object {
    $_.Name -match '(?i)(token.?cache|msal.*cache|\.log$|\.state\.json$|\.bin$|\.tmp$)' -or $_.Extension -in @('.pfx', '.pem', '.key')
})
if ($unexpected.Count) { throw 'Release contains unexpected personal/cache/log/temporary files.' }
$runtime = Get-Content -LiteralPath (Join-Path $data 'StarlightInn.runtimeconfig.json') -Raw | ConvertFrom-Json
if ($runtime.runtimeOptions.tfm -ne 'net8.0' -or -not @($runtime.runtimeOptions.includedFrameworks | Where-Object { $_.name -eq 'Microsoft.NETCore.App' -and $_.version -like '8.*' }).Count) {
    throw 'Export is not the expected self-contained net8.0 runtime.'
}
$deps = Get-Content -LiteralPath (Join-Path $data 'StarlightInn.deps.json') -Raw | ConvertFrom-Json
foreach ($package in @('Microsoft.Identity.Client/4.90.1', 'Microsoft.Identity.Client.Broker/4.90.1')) {
    if ($package -notin $deps.libraries.PSObject.Properties.Name) { throw "Missing locked release dependency: $package" }
}
$sourceDll = Join-Path $root '.godot\mono\temp\bin\ExportRelease\win-x64\StarlightInn.dll'
if ((Get-FileHash -LiteralPath $sourceDll).Hash -ne (Get-FileHash -LiteralPath (Join-Path $data 'StarlightInn.dll')).Hash) {
    throw 'Exported production DLL differs from current publish output.'
}
# Read the Godot 4 embedded PCK, not execute it. Verify every entry's MD5
# (the pack's integrity field) and SHA256 against current resources on disk.
$stream = [IO.File]::OpenRead($exe)
$reader = [IO.BinaryReader]::new($stream)
$packEntries = @()
try {
    [void]$stream.Seek(-12, [IO.SeekOrigin]::End)
    $packSize = $reader.ReadUInt64()
    if ($reader.ReadUInt32() -ne 0x43504447) { throw 'Missing embedded PCK footer.' }
    $packStart = $stream.Length - 12 - [long]$packSize
    [void]$stream.Seek($packStart, [IO.SeekOrigin]::Begin)
    if ($reader.ReadUInt32() -ne 0x43504447 -or $reader.ReadUInt32() -ne 4) { throw 'Unexpected embedded PCK format.' }
    [void]$stream.Seek($packStart + 24, [IO.SeekOrigin]::Begin)
    $fileBase = $reader.ReadUInt64()
    $directoryOffset = $reader.ReadUInt64()
    [void]$stream.Seek($packStart + [long]$directoryOffset, [IO.SeekOrigin]::Begin)
    $entryCount = $reader.ReadUInt32()
    for ($i = 0; $i -lt $entryCount; $i++) {
        $pathLength = $reader.ReadInt32()
        if ($pathLength -le 0 -or $pathLength -gt 4096) { throw 'Invalid PCK path length.' }
        $path = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($pathLength)).TrimEnd([char]0)
        $offset = $reader.ReadUInt64(); $length = $reader.ReadUInt64()
        $expectedMd5 = [Convert]::ToHexString($reader.ReadBytes(16))
        $flags = $reader.ReadUInt32(); $nextEntry = $stream.Position
        if ($flags -ne 0 -or $length -gt [int]::MaxValue -or
            $packStart + [long]$fileBase + [long]$offset + [long]$length -gt $packStart + [long]$directoryOffset) { throw 'Unsafe PCK entry bounds/flags.' }
        if ($path -match '(^|/)(tests|tools|qa|play|source)/|session-profile|azure-settings\.json|(^|/)\.\./' -or [IO.Path]::IsPathRooted($path)) { throw 'Excluded/personal file found inside PCK.' }
        [void]$stream.Seek($packStart + [long]$fileBase + [long]$offset, [IO.SeekOrigin]::Begin)
        $bytes = $reader.ReadBytes([int]$length)
        if ($bytes.Length -ne $length -or [Convert]::ToHexString([Security.Cryptography.MD5]::HashData($bytes)) -ne $expectedMd5) { throw "PCK integrity mismatch: $path" }
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $csharpStub = $path.EndsWith('.cs')
        if ($csharpStub -and ($bytes.Length -ne 1 -or $bytes[0] -ne 10)) { throw "Unexpected C# export placeholder: $path" }
        $sourcePath = Join-Path $root $path
        # UID/global metadata may be updated by the exporter after packing.
        # Compare authored resources and current imported/exported resources,
        # while still checking EVERY packed entry's integrity above.
        $comparable = $path -match '^(assets/|scripts/|\.godot/(imported|exported)/|main\.tscn\.remap$)' -and -not $path.EndsWith('.import') -and -not $csharpStub
        $matchesCurrentFile = $comparable -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)
        if ($matchesCurrentFile -and (Get-FileHash -LiteralPath $sourcePath).Hash -ne $sha256) { throw "PCK differs from current source/imported resource: $path" }
        $packEntries += [ordered]@{ path = $path; bytes = $length; sha256 = $sha256; matches_current_file = $matchesCurrentFile; csharp_placeholder = $csharpStub }
        [void]$stream.Seek($nextEntry, [IO.SeekOrigin]::Begin)
    }
} finally { $reader.Dispose(); $stream.Dispose() }
$textures = @($packEntries | Where-Object { $_.path -like '.godot/imported/*.ctex' -and $_.matches_current_file })
$samples = @($packEntries | Where-Object { $_.path -like '.godot/imported/*.sample' -and $_.matches_current_file })
if ($textures.Count -ne 38 -or $samples.Count -ne 9) { throw "Embedded imported asset mismatch: textures=$($textures.Count) samples=$($samples.Count)" }
if (@($packEntries | Where-Object { $_.csharp_placeholder }).Count -ne 4) { throw 'Expected four C# placeholders; implementation verified against production DLL.' }
if ($StaticOnly) {
    $result = [ordered]@{
        passed = $true; probe = 'static artifacts only; executable NOT started'
        executable = $exe; empty_public_template = $emptyTemplate; existing_public_config_preserved = $true
        runtime = $runtime.runtimeOptions; artifacts = $artifacts; production_dll_matches_publish = $true
        embedded_pck = $packEntries; production_textures = $textures.Count; production_samples = $samples.Count
        docs_match_source = $true; personal_profile_excluded = $true
        gui_started = $false; authentication_performed = $false; cloud_called = $false
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $qa 'azure-release-static-verification.json') -Encoding utf8
    if (-not $emptyTemplate) { Write-Warning 'Existing public configuration is set and preserved; no runtime/authentication probe performed.' }
    Write-Output "EXPORT_STATIC_TEST: passed; $($artifacts.Count) artifacts; DLL/docs hashes match; self-contained net8.0; no personal profile; EXE NOT started"
    return
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$log = Join-Path $qa "azure-release-$stamp.log"
$statePath = Join-Path $qa "azure-release-$stamp.state.json"
# qa, not play or project root: catches accidental CWD/res:// config lookup.
$arguments = @('--rendering-driver', 'opengl3_angle', '--quit-after', '120', '--verbose', '--log-file', $log, '--', ('--qa-state=' + $statePath))
$process = Start-Process -FilePath $exe -WorkingDirectory $qa -ArgumentList $arguments -PassThru
$start = $process.StartTime.ToUniversalTime().ToString('o')
if (-not $process.WaitForExit(120000)) { throw "Release probe PID $($process.Id) exceeded 120 seconds; not forcibly terminated." }
if ($process.ExitCode -ne 0) { throw "Release probe exit code: $($process.ExitCode)" }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if (-not [IO.Path]::IsPathRooted($state.azure_config_path) -or $state.azure_config_path -ne $configPath) { throw "Release config path is not EXE-adjacent: $($state.azure_config_path)" }
if (-not $state.azure_bridge_available -or $state.azure_configured -or $state.azure_connected -or $state.azure_busy -or $state.azure_operation_count -ne 0 -or $state.network_enabled -or $state.audio_muted) {
    throw 'Unexpected default release state (bridge/config/auth/jobs/audio).'
}
$expectedProfile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'StarlightInn\Azure\session-profile.v1.bin'
if ($state.azure_profile_path -ne $expectedProfile -or -not $state.azure_auto_login -or $state.azure_has_identity -or $state.azure_restoring -or $state.azure_panel) { throw 'Unexpected silent-restore defaults or user profile path.' }
$text = Get-Content -LiteralPath $log -Raw
if ($text -notmatch 'AZURE_BRIDGE_READY' -or $text -notmatch 'STARLIGHT_INN_READY') { throw 'Actual exported EXE did not reach both READY markers.' }
if ($text -match 'SCRIPT ERROR|Failed to load|Unable to load|Could not load|assembly.*not found') { throw 'Exported assembly/script/resource load failed.' }
$issues = @($text -split '\r?\n' | Where-Object { $_ -match '^ERROR:|^WARNING:|Leaked instance:' })
$result = [ordered]@{
    passed = $true; probe = 'actual exported EXE, non-EXE working directory, no authentication or cloud write'
    executable = $exe; pid = $process.Id; start_utc = $start; exit_code = $process.ExitCode
    config_path = $state.azure_config_path; configured = $state.azure_configured; connected = $state.azure_connected
    profile_path = $state.azure_profile_path; auto_login = $state.azure_auto_login; has_identity = $state.azure_has_identity; restoring = $state.azure_restoring
    operation_count = $state.azure_operation_count; audio_muted = $state.audio_muted
    runtime = $runtime.runtimeOptions; artifacts = $artifacts; observed_runtime_issues = $issues
    state_file = $statePath; log_file = $log
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $qa 'azure-release-verification.json') -Encoding utf8
Write-Output "EXPORT_TEST: passed; $($artifacts.Count) artifacts; self-contained net8.0; actual EXE READY; EXE-adjacent empty config; no login/cloud write"
if ($issues.Count) { Write-Output ('Observed runtime issues (not hidden): ' + ($issues -join ' | ')) }