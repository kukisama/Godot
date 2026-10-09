[CmdletBinding()]
param([string]$ExpectedPlayConfigSHA256 = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$play = Join-Path $root 'play'
$allowed = @('StarlightInn.exe','native/StarlightAzure.exe','azure-settings.json','README.md','API.md','AAD_SETUP.md')
$files = @(Get-ChildItem -LiteralPath $play -Recurse -File)
$actual = @($files | ForEach-Object { [IO.Path]::GetRelativePath($play,$_.FullName).Replace('\','/') } | Sort-Object)
if (($actual -join '|') -ne (($allowed | Sort-Object) -join '|')) { throw 'Release directory violates exact allowlist' }
$artifacts = @($files | ForEach-Object { [ordered]@{path=[IO.Path]::GetRelativePath($play,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash} })
foreach($doc in @('README.md','AAD_SETUP.md','API.md')) { if((Get-FileHash (Join-Path $root $doc)).Hash -ne (Get-FileHash (Join-Path $play $doc)).Hash){throw "Document mismatch: $doc"} }
if((Get-FileHash (Join-Path $root 'native/StarlightAzure.exe')).Hash -ne (Get-FileHash (Join-Path $play 'native/StarlightAzure.exe')).Hash){throw 'Helper differs from compiled source artifact'}
if((Get-FileHash (Join-Path $root 'qa/native-build/StarlightAzure.exe')).Hash -ne (Get-FileHash (Join-Path $play 'native/StarlightAzure.exe')).Hash){throw 'Helper differs from latest build output'}
$helperText=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $play 'native/StarlightAzure.exe')))
foreach($action in @('fixture_gate','fixture_release','fixture_fault_release','fixture_arm_execute_fault','fixture_stats','fixture_evidence','fixture_auth_fault','fixture_boot_fault','CANARY_SECRET')){if($helperText.Contains($action)){throw "Production helper contains fixture action: $action"}}
$baselinePath=Join-Path $root 'qa/review-fix-baseline.json'
$baseline=Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
$runStatus=Get-Content (Join-Path $root 'qa/review-final-run-status.json') -Raw | ConvertFrom-Json
if($runStatus.bridge_source_sha256 -ne (Get-FileHash (Join-Path $root 'scripts/azure_bridge.gd')).Hash){throw 'Executed tests do not match current bridge source'}
$expectedExits=@('build','import','core','pipe','test_azure','test_game','test_facing','test_dialogue','test_sound','pcm','export')
if((@($runStatus.exits.PSObject.Properties.Name | Sort-Object) -join '|') -ne (($expectedExits | Sort-Object) -join '|')){throw 'Missing actual final exit code'}
foreach($exit in $runStatus.exits.PSObject.Properties){if($exit.Value -ne 0){throw ('Actual execution failed: '+$exit.Name)}}
$currentAssets=@(Get-ChildItem -LiteralPath (Join-Path $root 'assets') -Recurse -File)
if($currentAssets.Count -ne $baseline.assets.Count){throw 'Source asset inventory changed'}
foreach($asset in $baseline.assets){if((Get-FileHash -LiteralPath (Join-Path $root $asset.path)).Hash -ne $asset.sha256){throw ('Source asset bytes changed: '+$asset.path)}}
if((Get-FileHash (Join-Path $root 'azure-settings.json')).Hash -ne $baseline.config_sha256){throw 'Source public template changed'}
$diagnosticBaselinePath = Join-Path $root 'qa/auth-diagnostics-baseline.json'
if ([string]::IsNullOrEmpty($ExpectedPlayConfigSHA256)) {
    $ExpectedPlayConfigSHA256 = if (Test-Path -LiteralPath $diagnosticBaselinePath) { (Get-Content -LiteralPath $diagnosticBaselinePath -Raw | ConvertFrom-Json).play_config_sha256 } else { $baseline.play_config_sha256 }
}
if($ExpectedPlayConfigSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash (Join-Path $play 'azure-settings.json')).Hash -ne $ExpectedPlayConfigSHA256){throw 'User public configuration bytes changed from the reviewed baseline'}
$projectText=Get-Content (Join-Path $root 'project.godot') -Raw
if($projectText -match '(?i)\[dotnet\]|C#|mono' -or $projectText -notmatch 'config/features=PackedStringArray\("4.7", "GL Compatibility"\)'){throw 'Not the standard GD project'}
$activeCs=@(Get-ChildItem (Join-Path $root 'scripts') -Recurse -File -Filter '*.cs')+@(Get-ChildItem -LiteralPath $root -File | Where-Object {$_.Extension -in '.cs','.csproj','.sln'})
if($activeCs.Count){throw 'Active C# project/source found'}
$config = Get-Content -LiteralPath (Join-Path $play 'azure-settings.json') -Raw | ConvertFrom-Json
if((@($config.PSObject.Properties.Name | Sort-Object) -join ',') -ne 'client_id,initial_tenant'){throw 'Public config schema changed'}
# A user's legitimate saved public ID is not the archived empty template.
$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if($config.client_id -isnot [string] -or $config.initial_tenant -isnot [string] -or
    ($config.client_id -ne '' -and ($config.client_id -notmatch $guidPattern -or $config.client_id -eq '00000000-0000-0000-0000-000000000000')) -or
    ($config.initial_tenant -ne 'organizations' -and ($config.initial_tenant -notmatch $guidPattern -or $config.initial_tenant -eq '00000000-0000-0000-0000-000000000000'))){throw 'Invalid public configuration; no values are printed'}
$dumpbin='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\dumpbin.exe'
$imports=@{}
foreach($relative in @('StarlightInn.exe','native/StarlightAzure.exe')){
    $path=Join-Path $play $relative
    $text=(& $dumpbin /dependents $path | Out-String)
    if($LASTEXITCODE -ne 0){throw 'PE dependencies probe failed'}
    $dlls=@([regex]::Matches($text,'(?im)^\s+([\w.-]+\.dll)\s*$') | ForEach-Object { $_.Groups[1].Value })
    if(-not $dlls.Count -or ($dlls -join '|') -match '(?i)coreclr|hostfxr|hostpolicy|msal|Microsoft\.Identity|msvcp\d|vcruntime\d'){throw 'Unexpected runtime dependency'}
    $headers=(& $dumpbin /headers $path | Out-String)
    if($headers -notmatch '(?im)^\s*0\s+\[\s*0\]\s+.*(?:COM Descriptor|CLR Runtime Header)'){throw 'PE CLR directory not verified empty'}
    $imports[$relative]=$dlls
}
$stream=[IO.File]::OpenRead((Join-Path $play 'StarlightInn.exe'))
$reader=[IO.BinaryReader]::new($stream)
$entries=@()
try{
    [void]$stream.Seek(-12,[IO.SeekOrigin]::End);$size=$reader.ReadUInt64()
    if($reader.ReadUInt32() -ne 0x43504447){throw 'Missing PCK footer'}
    $start=$stream.Length-12-[long]$size
    [void]$stream.Seek($start,[IO.SeekOrigin]::Begin)
    if($reader.ReadUInt32() -ne 0x43504447 -or $reader.ReadUInt32() -ne 4){throw 'Unexpected PCK format'}
    [void]$stream.Seek($start+24,[IO.SeekOrigin]::Begin);$base=$reader.ReadUInt64();$dir=$reader.ReadUInt64()
    [void]$stream.Seek($start+[long]$dir,[IO.SeekOrigin]::Begin);$count=$reader.ReadUInt32()
    for($i=0;$i -lt $count;$i++){
        $n=$reader.ReadInt32();if($n -le 0 -or $n -gt 4096){throw 'Unsafe PCK path length'}
        $path=[Text.Encoding]::UTF8.GetString($reader.ReadBytes($n)).TrimEnd([char]0)
        $offset=$reader.ReadUInt64();$length=$reader.ReadUInt64();$md5=[Convert]::ToHexString($reader.ReadBytes(16));$flags=$reader.ReadUInt32();$next=$stream.Position
        if($flags -ne 0 -or $length -gt [int]::MaxValue -or $start+[long]$base+[long]$offset+[long]$length -gt $start+[long]$dir){throw 'Unsafe PCK entry bounds'}
        if($path -match '(^|/)(tests|tools|qa|play|archive|native|source)/|\.cs$|\.dll$|\.csproj$|session-profile|azure-settings\.json|(^|/)\.\./' -or [IO.Path]::IsPathRooted($path)){throw "Excluded entry: $path"}
        [void]$stream.Seek($start+[long]$base+[long]$offset,[IO.SeekOrigin]::Begin);$bytes=$reader.ReadBytes([int]$length)
        if($bytes.Length -ne $length -or [Convert]::ToHexString([Security.Cryptography.MD5]::HashData($bytes)) -ne $md5){throw "PCK MD5: $path"}
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes));$disk=Join-Path $root $path
        $comparable=$path -match '^(assets/|scripts/|\.godot/(imported|exported)/)' -and -not $path.EndsWith('.import') -and (Test-Path -LiteralPath $disk -PathType Leaf)
        if($comparable -and (Get-FileHash -LiteralPath $disk).Hash -ne $hash){throw "PCK current resource mismatch: $path"}
        $entries += [ordered]@{path=$path;bytes=$length;sha256=$hash;matches_current=$comparable}
        [void]$stream.Seek($next,[IO.SeekOrigin]::Begin)
    }
}finally{$reader.Dispose();$stream.Dispose()}
$textures=@($entries | Where-Object {$_.path -like '.godot/imported/*.ctex' -and $_.matches_current})
$samples=@($entries | Where-Object {$_.path -like '.godot/imported/*.sample' -and $_.matches_current})
if($textures.Count -ne 38 -or $samples.Count -ne 9){throw "Asset count: $($textures.Count)/$($samples.Count)"}
$bridgeEntry=@($entries | Where-Object {$_.path -eq 'scripts/azure_bridge.gdc'})
$previous=Get-Content (Join-Path $root 'qa/native-release-verification.previous.json') -Raw | ConvertFrom-Json
$previousBridge=@($previous.embedded_pck | Where-Object {$_.path -eq 'scripts/azure_bridge.gdc'})
if($bridgeEntry.Count -ne 1 -or $previousBridge.Count -ne 1 -or $bridgeEntry[0].sha256 -eq $previousBridge[0].sha256){throw 'PCK still contains the pre-fix bridge bytecode'}
# Compare every original packed texture/sample against backed-up legacy EXE,
# independently of source timestamps or a newly generated manifest.
$old=[IO.File]::OpenRead((Join-Path $root 'qa/legacy-dotnet/play/StarlightInn.exe'));$br=[IO.BinaryReader]::new($old)
$unchanged=0
try{
    [void]$old.Seek(-12,[IO.SeekOrigin]::End);$sz=$br.ReadUInt64();[void]$br.ReadUInt32();$st=$old.Length-12-[long]$sz
    [void]$old.Seek($st+24,[IO.SeekOrigin]::Begin);$bs=$br.ReadUInt64();$di=$br.ReadUInt64();[void]$old.Seek($st+[long]$di,[IO.SeekOrigin]::Begin);$ct=$br.ReadUInt32()
    for($i=0;$i -lt $ct;$i++){$n=$br.ReadInt32();$p=[Text.Encoding]::UTF8.GetString($br.ReadBytes($n)).TrimEnd([char]0);$o=$br.ReadUInt64();$l=$br.ReadUInt64();[void]$br.ReadBytes(20);$next=$old.Position
        if($p -match '^\.godot/imported/.*\.(ctex|sample)$'){[void]$old.Seek($st+[long]$bs+[long]$o,[IO.SeekOrigin]::Begin);$h=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($br.ReadBytes([int]$l)));$new=@($entries | Where-Object {$_.path -eq $p});if($new.Count -ne 1 -or $new[0].sha256 -ne $h){throw "Legacy art/audio changed: $p"};$unchanged++};[void]$old.Seek($next,[IO.SeekOrigin]::Begin)}
}finally{$br.Dispose();$old.Dispose()}
if($unchanged -ne 47){throw 'Legacy resources comparison incomplete'}
$zipPath=Join-Path $root 'StarlightInn-Windows.zip';$zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
try{if($zip.Entries.Count -ne $allowed.Count -or ((@($zip.Entries | ForEach-Object {$_.FullName} | Sort-Object) -join '|') -cne (@($allowed | ForEach-Object {'play/'+$_} | Sort-Object) -join '|'))){throw 'ZIP exact names/count mismatch'};foreach($entry in $zip.Entries){$p=$entry.FullName;if(-not $p.StartsWith('play/') -or $p.Substring(5) -notin $allowed){throw "Unexpected ZIP entry: $p"};$s=$entry.Open();try{$hash=[Security.Cryptography.SHA256]::Create();try{$h=[Convert]::ToHexString($hash.ComputeHash($s))}finally{$hash.Dispose()}}finally{$s.Dispose()};if($h -ne (Get-FileHash (Join-Path $root $p)).Hash){throw "ZIP hash mismatch: $p"}}}finally{$zip.Dispose()}
$oldPlay=Join-Path $root 'qa/legacy-dotnet/play';$oldTotal=(Get-ChildItem $oldPlay -Recurse -File | Measure-Object Length -Sum).Sum
$testCounts=@{}
foreach($pair in @(@('core','offline-native-core.log'),@('pipe','offline-native-pipe.log'),@('azure_ui','offline-native-test_azure.log'),@('game','offline-native-test_game.log'),@('facing','offline-native-test_facing.log'),@('dialogue','offline-native-test_dialogue.log'),@('sound','offline-native-test_sound.log'))){
    $log=Get-Content -LiteralPath (Join-Path $root ('qa/'+$pair[1])) -Raw
    if($log -match '(?im)^ERROR:|^WARNING:|SCRIPT ERROR|\bFAIL\b|warning C\d|error C\d'){throw ('Test diagnostics: '+$pair[0])}
    $matchesFound=[regex]::Matches($log,'(?m)^\w+_TESTS: (\d+) passed, 0 failed')
    if($matchesFound.Count -ne 1){throw ('Missing test result: '+$pair[0])}
    $testCounts[$pair[0]]=[int]$matchesFound[0].Groups[1].Value
    if((Get-Item (Join-Path $root ('qa/'+$pair[1]))).LastWriteTimeUtc -lt (Get-Item $baselinePath).LastWriteTimeUtc){throw ('Stale test log: '+$pair[0])}
}
$pcm=Get-Content -LiteralPath (Join-Path $root 'qa/offline-native-pcm.log') -Raw
if($pcm -match '(?im)^ERROR:|^WARNING:|SCRIPT ERROR|\bFAIL\b'){throw 'PCM diagnostics'}
if($pcm -notmatch 'AUDIO_CHECK PASS \| files=9 \| assertions=(\d+) \| failures=0 \| no playback'){throw 'PCM result missing'}
$testCounts['pcm']=[int]$matches[1]
$readme=Get-Content (Join-Path $root 'README.md') -Raw
foreach($count in $testCounts.Values){if($readme -notmatch ('\| '+$count+' / 0')){throw ('README test count is stale: '+$count)}}
foreach($name in @('native-build.log','native-import.log','native-export.log')){if((Get-Content (Join-Path $root ('qa/'+$name)) -Raw) -match '(?im)^ERROR:|^WARNING:|SCRIPT ERROR|warning C\d|error C\d'){throw ('Build/import/export diagnostics: '+$name)}}
$result=[ordered]@{passed=$true;architecture='standard Godot GD + /MT native WinRT WAM/private pipe/ARM';gui_started=$false;authentication_performed=$false;cloud_called=$false;personal_profile_read=$false;old_exe_bytes=(Get-Item (Join-Path $oldPlay 'StarlightInn.exe')).Length;old_total_bytes=$oldTotal;old_zip_bytes=(Get-Item (Join-Path $root 'qa/legacy-dotnet/StarlightInn-Windows.zip')).Length;total_bytes=($files | Measure-Object Length -Sum).Sum;zip_bytes=(Get-Item $zipPath).Length;zip_sha256=(Get-FileHash $zipPath).Hash;artifacts=$artifacts;pe_imports=$imports;embedded_pck=$entries;unchanged_legacy_imported_assets=$unchanged;production_textures=38;production_samples=9;public_config_preserved=$true;native_test_log='offline-native-core.log';pipe_test_log='offline-native-pipe.log'}
$result['test_counts']=$testCounts
$result['test_assertions_total']=($testCounts.Values | Measure-Object -Sum).Sum
$result['diagnostic_errors']=0;$result['diagnostic_warnings']=0
$result['timestamp_utc']=[DateTime]::UtcNow.ToString('o')
$result['execution_exit_codes']=$runStatus.exits
$result['source_assets_unchanged']=$true;$result['source_asset_file_count']=$currentAssets.Count
$result['docs_match_source']=$true;$result['production_helper_matches_build']=$true;$result['fixture_controls_excluded']=$true
$result['bridge_bytecode_changed']=$true;$result['bridge_bytecode_sha256']=$bridgeEntry[0].sha256
$result['source_sha256']=[ordered]@{}
foreach($path in @('scripts/azure_bridge.gd','native/core.hpp','native/core.cpp','native/protocol.cpp','tests/native_tests.cpp','tests/native_fake.hpp','tests/test_native_pipe.gd','tests/pipe_test_bridge.gd','tests/verify_native_export.ps1','native/build.ps1','project.godot','export_presets.cfg')){$result.source_sha256[$path]=(Get-FileHash (Join-Path $root $path)).Hash}
$result['source_png_count']=@(Get-ChildItem -LiteralPath (Join-Path $root 'assets') -Recurse -File -Filter '*.png').Count
$result['old_data_bytes']=(Get-ChildItem (Join-Path $oldPlay 'data_StarlightInn_windows_x86_64') -Recurse -File | Measure-Object Length -Sum).Sum
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'qa/native-release-verification.json') -Encoding utf8
$summary=[ordered]@{passed=$true;timestamp_utc=$result.timestamp_utc;baseline_core='215 passed, 2 failed';baseline_pipe='60 passed, 12 failed';test_counts=$testCounts;test_assertions_total=$result.test_assertions_total;diagnostic_errors=0;diagnostic_warnings=0;gui_started=$false;authentication_performed=$false;cloud_called=$false;personal_profile_read=$false;source_assets_unchanged=$true;source_asset_file_count=$currentAssets.Count;unchanged_legacy_imported_assets=$unchanged;public_config_preserved=$true;docs_match_source=$true;production_helper_matches_build=$true;fixture_controls_excluded=$true;bridge_bytecode_changed=$true;bridge_bytecode_sha256=$bridgeEntry[0].sha256;source_sha256=$result.source_sha256;total_bytes=$result.total_bytes;zip_bytes=$result.zip_bytes;zip_sha256=$result.zip_sha256;artifacts=$artifacts}
$summary['execution_exit_codes']=$runStatus.exits
$summary['late_terminal_before']='173 passed, 2 failed'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'qa/native-final-verification.json') -Encoding utf8
if (Test-Path -LiteralPath $diagnosticBaselinePath) {
    $probe = Get-Content -LiteralPath (Join-Path $root 'qa/wam-discovery.json') -Raw | ConvertFrom-Json
    if($probe.authentication_performed -ne $false -or $probe.personal_profile_read -ne $false -or $probe.cloud_called -ne $false){throw 'Discovery probe safety evidence missing'}
    $diagnosticBaseline = Get-Content -LiteralPath $diagnosticBaselinePath -Raw | ConvertFrom-Json
    foreach($name in @('auth-native-build.log','auth-import.log','auth-export.log')){if((Get-Content (Join-Path $root ('qa/'+$name)) -Raw) -match '(?im)^ERROR:|^WARNING:|SCRIPT ERROR|warning C\d|error C\d'){throw ('Diagnostics build/import/export warning: '+$name)}}
    foreach($path in @('offline-native-core.log','offline-native-pipe.log')){if((Get-Content (Join-Path $root ('qa/'+$path)) -Raw).Contains('CANARY_SECRET')){throw 'Sensitive exception canary escaped into log'}}
    $diagnostics = [ordered]@{passed=$true;timestamp_utc=$result.timestamp_utc;windows=$diagnosticBaseline.environment;discovery=$probe;login_root_cause_confirmed=$false;root_cause_status='Factory/interop/provider available; real user-driven token request remains untested. Original native error details were discarded; fixed safe diagnostics.';gui_started=$false;authentication_performed=$false;cloud_called=$false;personal_profile_read=$false;system_modified=$false;test_counts=$testCounts;test_assertions_total=$result.test_assertions_total;diagnostic_errors=0;diagnostic_warnings=0;public_config_sha256=$ExpectedPlayConfigSHA256;public_config_preserved=$true;zip_config_bytes_match=$true;source_assets_unchanged=$true;source_asset_file_count=$currentAssets.Count;unchanged_legacy_imported_assets=$unchanged;artifacts=$artifacts;zip_sha256=$result.zip_sha256;source_sha256=$result.source_sha256;execution_exit_codes=$runStatus.exits;previous_reports='qa/auth-diagnostics-history';native_hresult_canary_tested=$true;provider_numeric_only=$true;boot_error_pipe_tested=$true;user_click_required=$true}
    $diagnostics | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'qa/auth-diagnostics-verification.json') -Encoding utf8
}
Write-Output "EXPORT_STATIC_TEST: passed; $($artifacts.Count) artifacts; $($entries.Count) PCK entries; 47 legacy assets identical; no .NET/MSAL/GUI/profile/auth/cloud"
Write-Output ("SIZE_BYTES old_exe={0} old_total={1} old_zip={2} new_total={3} new_zip={4}" -f $result.old_exe_bytes,$oldTotal,$result.old_zip_bytes,$result.total_bytes,$result.zip_bytes)
$artifacts | ForEach-Object { Write-Output ("ARTIFACT {0} {1} bytes SHA256={2}" -f $_.path,$_.bytes,$_.sha256) }
Write-Output ('ZIP_SHA256='+$result.zip_sha256)