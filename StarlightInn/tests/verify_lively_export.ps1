[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedPlayConfigSHA256,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSourceConfigSHA256
)

# Static delivery check for the expanded artwork. Never runs GUI/auth/cloud.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$play = Join-Path $root 'play'
$allowed = @('StarlightInn.exe', 'native/StarlightAzure.exe', 'azure-settings.json', 'README.md', 'API.md', 'AAD_SETUP.md')
$files = @(Get-ChildItem -LiteralPath $play -Recurse -File)
$actual = @($files | ForEach-Object { [IO.Path]::GetRelativePath($play, $_.FullName).Replace('\', '/') } | Sort-Object)
if (($actual -join '|') -cne (($allowed | Sort-Object) -join '|')) { throw 'Unexpected play directory contents' }
if ((Get-FileHash -LiteralPath (Join-Path $play 'azure-settings.json')).Hash -ne $ExpectedPlayConfigSHA256 -or
    (Get-FileHash -LiteralPath (Join-Path $root 'azure-settings.json')).Hash -ne $ExpectedSourceConfigSHA256) {
    throw 'Public Azure configuration changed'
}
foreach ($doc in @('README.md', 'API.md', 'AAD_SETUP.md')) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $doc)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $play $doc)).Hash) {
        throw "Packaged document differs: $doc"
    }
}
if ((Get-FileHash -LiteralPath (Join-Path $root 'qa/native-build/StarlightAzure.exe')).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $play 'native/StarlightAzure.exe')).Hash) {
    throw 'Packaged helper differs from the existing latest native build'
}
$stream = [IO.File]::OpenRead((Join-Path $play 'StarlightInn.exe'))
$reader = [IO.BinaryReader]::new($stream)
$entries = @()
try {
    [void]$stream.Seek(-12, [IO.SeekOrigin]::End)
    $size = $reader.ReadUInt64()
    if ($reader.ReadUInt32() -ne 0x43504447) { throw 'Missing embedded PCK footer' }
    $start = $stream.Length - 12 - [long]$size
    [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
    if ($reader.ReadUInt32() -ne 0x43504447 -or $reader.ReadUInt32() -ne 4) { throw 'Unexpected PCK format' }
    [void]$stream.Seek($start + 24, [IO.SeekOrigin]::Begin)
    $base = $reader.ReadUInt64()
    $directory = $reader.ReadUInt64()
    [void]$stream.Seek($start + [long]$directory, [IO.SeekOrigin]::Begin)
    $count = $reader.ReadUInt32()
    for ($index = 0; $index -lt $count; $index++) {
        $length = $reader.ReadInt32()
        if ($length -le 0 -or $length -gt 4096) { throw 'Invalid PCK path length' }
        $path = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($length)).TrimEnd([char]0)
        $offset = $reader.ReadUInt64()
        $bytes = $reader.ReadUInt64()
        $md5 = [Convert]::ToHexString($reader.ReadBytes(16))
        $flags = $reader.ReadUInt32()
        $next = $stream.Position
        if ($flags -ne 0 -or $bytes -gt [int]::MaxValue -or
            $start + [long]$base + [long]$offset + [long]$bytes -gt $start + [long]$directory) {
            throw "Unsafe PCK entry: $path"
        }
        if ($path -match '(^|/)(tests|tools|qa|play|archive|native|source)/|\.cs$|\.dll$|\.csproj$|session-profile|azure-settings\.json|(^|/)\.\./' -or
            [IO.Path]::IsPathRooted($path)) { throw "Private/source/test resource exported: $path" }
        [void]$stream.Seek($start + [long]$base + [long]$offset, [IO.SeekOrigin]::Begin)
        $payload = $reader.ReadBytes([int]$bytes)
        if ($payload.Length -ne $bytes -or [Convert]::ToHexString([Security.Cryptography.MD5]::HashData($payload)) -ne $md5) {
            throw "PCK integrity mismatch: $path"
        }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload))
        $disk = Join-Path $root $path
        $matchesCurrent = $false
        if ($path -match '^\.godot/imported/.*\.(ctex|sample)$') {
            if (-not (Test-Path -LiteralPath $disk -PathType Leaf) -or (Get-FileHash -LiteralPath $disk).Hash -ne $hash) {
                throw "Packaged art/audio differs from current imported assets: $path"
            }
            $matchesCurrent = $true
        }
        $entries += [ordered]@{ path = $path; bytes = $bytes; sha256 = $hash; matches_current = $matchesCurrent }
        [void]$stream.Seek($next, [IO.SeekOrigin]::Begin)
    }
} finally { $reader.Dispose(); $stream.Dispose() }

$textures = @($entries | Where-Object { $_.path -like '.godot/imported/*.ctex' })
$audio = @($entries | Where-Object { $_.path -like '.godot/imported/*.sample' })
if ($textures.Count -ne 210 -or $audio.Count -ne 9) { throw "Unexpected embedded art/audio count: $($textures.Count)/$($audio.Count)" }
foreach ($required in @('scripts/game.gdc', 'scripts/residents.gdc', 'scripts/npc_scenes.gdc', 'scripts/npc_catalog.gdc', 'scripts/dialogue.gdc', 'scripts/demo_provider.gdc', 'scripts/inn_ui.gdc', 'scripts/day_cycle.gdc', 'scripts/actor.gdc', 'scripts/azure_bridge.gdc')) {
    if (@($entries | Where-Object { $_.path -eq $required }).Count -ne 1) { throw "Missing gameplay script: $required" }
}
foreach ($phase in @('dawn', 'day', 'sunset', 'night')) {
    if (@($textures | Where-Object { $_.path -like ('.godot/imported/inn_hall_' + $phase + '.png-*.ctex') }).Count -ne 1) {
        throw "Missing background: $phase"
    }
}
foreach ($person in @('mira', 'oren', 'eve', 'finn', 'traveler')) {
    foreach ($direction in @('down', 'left', 'right', 'up')) {
        foreach ($frame in 0..7) {
            $pattern = '.godot/imported/' + $person + '_' + $direction + '_' + $frame + '.png-*.ctex'
            if (@($textures | Where-Object { $_.path -like $pattern }).Count -ne 1) { throw "Missing stride frame: $pattern" }
        }
    }
}
$zipPath = Join-Path $root 'StarlightInn-Windows.zip'
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $zipNames = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    $expectedNames = @($allowed | ForEach-Object { 'play/' + $_ } | Sort-Object)
    if (($zipNames -join '|') -cne ($expectedNames -join '|')) { throw 'ZIP does not match the play allowlist' }
    foreach ($entry in $zip.Entries) {
        $inputStream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [Convert]::ToHexString($sha.ComputeHash($inputStream)) } finally { $sha.Dispose(); $inputStream.Dispose() }
        if ($hash -ne (Get-FileHash -LiteralPath (Join-Path $root $entry.FullName)).Hash) { throw "Stale ZIP file: $($entry.FullName)" }
    }
} finally { $zip.Dispose() }
$result = [ordered]@{
    passed = $true; timestamp_utc = [DateTime]::UtcNow.ToString('o')
    gui_started = $false; authentication_performed = $false; cloud_called = $false
    production_textures = $textures.Count; production_audio = $audio.Count
    public_config_preserved = $true; documents_match = $true; current_imported_art_matches = $true
    zip_sha256 = (Get-FileHash -LiteralPath $zipPath).Hash
    artifacts = @($files | ForEach-Object { [ordered]@{
        path = [IO.Path]::GetRelativePath($play, $_.FullName).Replace('\', '/'); bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash
    } })
    embedded_pck = $entries
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qa/lively-package-verification.json') -Encoding utf8
Write-Output 'LIVELY_EXPORT_STATIC_TEST: PASS; 210 current textures, 9 original audio files, all eight-frame directions, six-file ZIP, public configuration preserved'