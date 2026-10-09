param(
    [ValidateSet('Static', 'Render', 'Build', 'Regression')][string]$Phase = 'Static',
    [switch]$RunPackagedCheck
)

$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$engine = Join-Path $env:LOCALAPPDATA 'Programs\Godot\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'Godot 4.7.2 console executable was not found.' }
$qa = Join-Path $project 'qa'
[void][IO.Directory]::CreateDirectory($qa)

function Invoke-Engine([string]$Name, [string[]]$Arguments, [string]$Marker = '', [string]$Executable = $engine, [string]$Directory = $project, [string]$SummaryPattern = '') {
    $stdout = Join-Path $qa ($Name + '-console.log')
    $stderr = Join-Path $qa ($Name + '-errors.log')
    $log = Join-Path $qa ($Name + '.log')
    $all = @($Arguments) + @('--log-file', $log)
    $quoted = $all | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $process = Start-Process -FilePath $Executable -ArgumentList $quoted -WorkingDirectory $Directory -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -Wait
    $text = [IO.File]::ReadAllText($stdout) + [IO.File]::ReadAllText($stderr)
    if ($process.ExitCode -ne 0 -or $text -match '(?m)^(?:SCRIPT ERROR|ERROR|FAIL)(?:\s|:)') {
        Get-Content -LiteralPath $stdout -Tail 12
        Get-Content -LiteralPath $stderr
        throw "$Name failed, exit=$($process.ExitCode). See $log"
    }
    if ($Marker -and -not $text.Contains($Marker)) { throw "$Name did not emit its completion marker: $Marker" }
    $summary = $Marker
    if ($SummaryPattern) {
        $match = [regex]::Match($text, $SummaryPattern)
        if (-not $match.Success) { throw "$Name did not emit a successful completion summary. See $log" }
        $summary = $match.Value.Trim()
    }
    Write-Output ("{0} EXIT=0 {1}" -f $Name, $summary)
}

function Invoke-StaticChecks {
    $records = [Collections.Generic.List[object]]::new()
    $gdFiles = @(Get-ChildItem -LiteralPath (Join-Path $project 'scripts'), (Join-Path $project 'tests'), (Join-Path $project 'tools') -Filter '*.gd' -File | Sort-Object FullName)
    foreach ($file in $gdFiles) {
        $relative = $file.FullName.Substring($project.Length + 1).Replace('\', '/')
        # --check-only parses the script; its _initialize/_ready and test
        # assertions are never executed. Do not substitute --quit-after.
        Invoke-Engine ('static-' + $file.BaseName) @('--headless', '--path', $project, '--script', ('res://' + $relative), '--check-only')
        $records.Add([pscustomobject]@{ File = $relative; Check = 'Godot parse only'; Passed = $true })
    }
    $psFiles = @(Get-ChildItem -LiteralPath (Join-Path $project 'tools'), (Join-Path $project 'tests') -Filter '*.ps1' -File | Sort-Object FullName)
    foreach ($file in $psFiles) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw ('PowerShell parse failed: ' + $file.Name + ': ' + ($parseErrors.Message -join '; ')) }
        $records.Add([pscustomobject]@{ File = $file.FullName.Substring($project.Length + 1); Check = 'PowerShell AST only'; Passed = $true })
    }
    $references = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $gdFiles | Where-Object { $_.Directory.Name -eq 'scripts' }) {
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($text, '"(?<path>res://[^"\r\n]+\.(?:gd|tscn|gdshader|png|ogg|wav))"')) {
            $resource = $match.Groups['path'].Value
            if ($resource.Contains('%')) { continue }
            $path = Join-Path $project $resource.Substring(6)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Missing literal production resource: ' + $resource) }
            [void]$references.Add($resource)
        }
    }
    $sheets = @('hero_v2_motion', 'hero_v2_blade_a', 'hero_v2_blade_b', 'hero_v2_defense')
    $assets = @(
        foreach ($name in $sheets) {
            $path = Join-Path $project ('assets\sprites\' + $name + '.png')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-Path -LiteralPath ($path + '.import') -PathType Leaf)) { throw ('Missing selected sprite/import: ' + $name) }
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes.Length -lt 24 -or [BitConverter]::ToString($bytes, 0, 8) -ne '89-50-4E-47-0D-0A-1A-0A') { throw ('Invalid PNG header: ' + $name) }
            $width = [BitConverter]::ToUInt32([byte[]]$bytes[19..16], 0)
            $height = [BitConverter]::ToUInt32([byte[]]$bytes[23..20], 0)
            if ($width -ne 1536 -or $height -ne 1024) { throw ('Incorrect 6x4 atlas dimensions: ' + $name) }
            [pscustomobject]@{ File = 'assets/sprites/' + $name + '.png'; Size = @($width, $height); SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
    )
    $report = [ordered]@{
        Scope = 'Static parse, source references and PNG header contracts only; no gameplay or animation-quality verdict.'
        CreatedUTC = [DateTime]::UtcNow.ToString('O')
        Passed = $true
        GDScriptParseChecks = $gdFiles.Count
        PowerShellParseChecks = $psFiles.Count
        LiteralProductionResources = $references.Count
        SelectedAtlases = $assets
        Checks = @($records)
        FunctionalTestsExecuted = 0
        GameStarted = $false
        TrueMachineAcceptance = 'Pending user testing by explicit request.'
    }
    [IO.File]::WriteAllText((Join-Path $qa 'player-v2-static.json'), ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Output ('STATIC_VERIFIED gd={0} ps={1} literal_resources={2} atlases=4 functional_tests=0 game_started=false' -f $gdFiles.Count, $psFiles.Count, $references.Count)
}

if ($RunPackagedCheck -and $Phase -ne 'Build') { throw '-RunPackagedCheck is only supported with -Phase Build.' }
Invoke-StaticChecks
if ($Phase -eq 'Static') { return }

# Import/export is an editor/compiler operation; it never runs main.tscn.
Invoke-Engine 'import-verified' @('--headless', '--editor', '--path', $project, '--quit')

if ($Phase -eq 'Render') {
    Invoke-Engine 'render-verified' @('--path', $project, '--rendering-driver', 'opengl3_angle', '--audio-driver', 'Dummy', '--fixed-fps', '60', '--script', 'res://tests/render_capture.gd') 'RENDER_CAPTURE_COMPLETE state=victory'
}
elseif ($Phase -eq 'Regression') {
    Invoke-Engine 'gameplay-final' @('--headless', '--audio-driver', 'Dummy', '--path', $project, '--fixed-fps', '60', '--script', 'res://tests/test_game.gd') -SummaryPattern '(?m)^GAME INTEGRATION: [1-9]\d* checks, 0 failures\r?$'
    Invoke-Engine 'enemy-final' @('--headless', '--audio-driver', 'Dummy', '--path', $project, '--fixed-fps', '60', '--script', 'res://tests/test_enemy_contract.gd') -SummaryPattern '(?m)^ENEMY CONTRACT: [1-9]\d* checks, 0 failures\r?$'
    # Four physics/render pairs; run only after production and selected art are ready.
    Invoke-Engine 'player-v2-final' @('--headless', '--audio-driver', 'Dummy', '--path', $project, '--script', 'res://tests/test_player_v2.gd') -SummaryPattern '(?m)^PLAYER V2: matrix children=4, parent checks=[1-9]\d*, failures=0; res://qa/player-v2-results\.json\r?$'
}
else {
    $delivery = [IO.Path]::GetFullPath((Join-Path $project '..\play'))
    [void][IO.Directory]::CreateDirectory($delivery)
    $exe = Join-Path $delivery 'HollowBell.exe'
    Invoke-Engine 'export-verified' @('--headless', '--path', $project, '--export-release', 'Windows Desktop', $exe)
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Export did not produce HollowBell.exe.' }
    if ($RunPackagedCheck) {
        Invoke-Engine 'packaged-verified' @('--headless', '--audio-driver', 'Dummy', '--quit-after', '120') 'HOLLOW_BELL_READY state=title enemy_kinds=8 encounters=15' $exe $delivery
    }
    else {
        Write-Output 'PACKAGED_RUNTIME_CHECK=NOT_RUN; GAME_STARTED=false; USER_TRUE_MACHINE_TEST=PENDING'
    }
    $item = Get-Item -LiteralPath $exe
    [pscustomobject]@{ Exe = $item.FullName; SizeMB = [Math]::Round($item.Length / 1MB, 2); SHA256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash } | Format-List
}