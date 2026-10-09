[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$qa = Join-Path $root 'qa'
$expected = 'ED418E072546E8E40C22332728DFD82BD9C0714012F880A000A0611DC183015B'
$configPath = Join-Path $root 'play/azure-settings.json'
function Assert-Config {
    if((Get-FileHash -LiteralPath $configPath).Hash -ne $expected){throw 'Public user configuration changed; refusing to continue'}
}
Assert-Config
$history = Join-Path $qa 'auth-diagnostics-history'
New-Item -ItemType Directory -Path $history -Force | Out-Null
foreach($name in @('native-final-verification.json','native-release-verification.json','review-final-run-status.json')) {
    $old = Join-Path $qa $name; $backup = Join-Path $history $name
    if((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $backup)){Copy-Item -LiteralPath $old -Destination $backup}
}
$os = Get-CimInstance Win32_OperatingSystem
$broker = @(Get-AppxPackage -Name Microsoft.AAD.BrokerPlugin | ForEach-Object {[ordered]@{version=$_.Version.ToString();architecture=$_.Architecture.ToString();status=$_.Status.ToString();install_location_exists=(Test-Path -LiteralPath $_.InstallLocation)}})
$environment = [ordered]@{build=$os.BuildNumber;version=$os.Version;process_session=(Get-Process -Id $PID).SessionId;broker=$broker}
$baselinePath=Join-Path $qa 'auth-diagnostics-baseline.json'
if(-not (Test-Path -LiteralPath $baselinePath)){
    [ordered]@{timestamp_utc=[DateTime]::UtcNow.ToString('o');play_config_sha256=$expected;environment=$environment;source_assets=@(Get-ChildItem -LiteralPath (Join-Path $root 'assets') -Recurse -File | ForEach-Object {[ordered]@{path=[IO.Path]::GetRelativePath($root,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $baselinePath -Encoding utf8
}
$status = [ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');bridge_source_sha256=(Get-FileHash (Join-Path $root 'scripts/azure_bridge.gd')).Hash;exits=[ordered]@{}}
function Run([string]$name,[string]$exe,[string[]]$arguments,[string]$log) {
    $start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$root
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    foreach($arg in $arguments){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $qa $log),$output,[Text.UTF8Encoding]::new($false))
    $status.exits[$name]=$process.ExitCode
    Write-Output ($name+' EXIT='+$process.ExitCode)
    if($process.ExitCode -ne 0 -or $output -match '(?im)^ERROR:|^WARNING:|SCRIPT ERROR|\bFAIL\b|warning C\d|error C\d'){throw ('Offline run failed: '+$name+'; inspect '+$log)}
    Assert-Config
}
$pwsh=(Get-Command pwsh -CommandType Application).Source
Run 'build' $pwsh @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $root 'native/build.ps1')) 'auth-native-build.log'
Run 'probe' (Join-Path $qa 'native-build/wam-probe.exe') @() 'wam-discovery.json'
$status.exits.Remove('probe')
$godot=(Get-ChildItem -LiteralPath (Join-Path $root 'tools/godot-standard') -File -Filter '*console.exe' | Select-Object -First 1).FullName
if(-not $godot){throw 'Project-local standard console Godot missing'}
Run 'import' $godot @('--headless','--path',$root,'--editor','--import') 'auth-import.log'
Run 'core' (Join-Path $qa 'native-build/native-tests.exe') @() 'offline-native-core.log'
Run 'pipe' $godot @('--headless','--path',$root,'--script','res://tests/test_native_pipe.gd') 'offline-native-pipe.log'
foreach($test in @('test_azure','test_game','test_facing','test_dialogue','test_sound')) {
    Run $test $godot @('--headless','--path',$root,'--script',('res://tests/'+$test+'.gd')) ('offline-native-'+$test+'.log')
}
Run 'pcm' $pwsh @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $root 'tests/check_audio.ps1')) 'offline-native-pcm.log'
Run 'export' $godot @('--headless','--path',$root,'--export-release','Windows Desktop',(Join-Path $root 'play/StarlightInn.exe')) 'auth-export.log'
# Compatibility names used by the static verifier refer to this actual run.
foreach($pair in @(@('auth-native-build.log','native-build.log'),@('auth-import.log','native-import.log'),@('auth-export.log','native-export.log'))){Copy-Item -LiteralPath (Join-Path $qa $pair[0]) -Destination (Join-Path $qa $pair[1])}
Copy-Item -LiteralPath (Join-Path $qa 'native-build/StarlightAzure.exe') -Destination (Join-Path $root 'native/StarlightAzure.exe')
Copy-Item -LiteralPath (Join-Path $qa 'native-build/StarlightAzure.exe') -Destination (Join-Path $root 'play/native/StarlightAzure.exe')
$status['completed_utc']=[DateTime]::UtcNow.ToString('o')
$status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $qa 'review-final-run-status.json') -Encoding utf8
Assert-Config
Write-Output 'OFFLINE_RUN_COMPLETE: no GUI/token requests/ARM/personal profile; docs and ZIP static verification still required'