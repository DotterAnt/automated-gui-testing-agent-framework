param([string]$OutFile,[ValidateRange(2,20)] [int]$Count=6)
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\Exploration.ps1')
. (Join-Path $frameworkRoot 'Framework\ExplorationHost.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-host-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$runs=@();$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Actual fixture observation' | Set-Content -LiteralPath $csv
    $cliRoot=Join-Path $root 'cli'
    [void][IO.Directory]::CreateDirectory($cliRoot)
    $sourceCli=Join-Path (Split-Path $frameworkRoot) 'potato-cli'
    Copy-Item -LiteralPath (Join-Path $sourceCli 'PoTAToCli') -Destination $cliRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceCli 'potato.ps1'),(Join-Path $sourceCli 'commands.json') -Destination $cliRoot
    $cli=Join-Path $cliRoot 'potato.ps1'
    $run=Join-Path $root 'host';$runs+=,$run
    Initialize-AGTAExploration $run $csv GuiNavigation $cli | Out-Null
    $request='[{"stepIndex":1,"command":"help","arguments":["-Topic","type"]}]'
    $parameters=@{Action='Batch';RunRoot=$run;RequestsJson=$request}
    $first=Invoke-AGTAExplorationHost $run $parameters
    Check ($first.exitCode -eq 0 -and ($first.responses[0] | ConvertFrom-Json).explorationCommandId) "Worker did not return a real exploration receipt: $($first | ConvertTo-Json -Depth 5 -Compress)"
    $second=Invoke-AGTAExplorationHost $run $parameters
    Check ($second.hostProcessId -eq $first.hostProcessId -and $second.exitCode -eq 0) 'Separate requests did not reuse the worker.'
    $wrongRun=Invoke-AGTAExplorationHost $run @{Action='Status';RunRoot=(Join-Path $root 'another-run')}
    Check ($wrongRun.exitCode -eq 1 -and ($wrongRun.responses[0] | ConvertFrom-Json).outcome -eq 'not-dispatched') 'Worker accepted a request for another run.'
    $parameters.RequestsJson='[{"stepIndex":1,"command":"help","arguments":["-Topic","missing"]},{"stepIndex":1,"command":"help","arguments":["-Topic","click"]}]'
    $failed=Invoke-AGTAExplorationHost $run $parameters
    Check ($failed.exitCode -eq 1 -and $failed.responses.Count -eq 1 -and -not ($failed.responses[0] | ConvertFrom-Json).ok) 'Worker continued a batch after failure.'
    $parameters.RequestsJson=$request
    $recovery=Invoke-AGTAExplorationHost $run $parameters
    Check ($recovery.exitCode -eq 0 -and $recovery.hostProcessId -eq $first.hostProcessId) 'A failed batch prevented a reviewed recovery request.'
    $records=@(Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl') | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($records.Count -eq 4 -and ($records[2].result.ok -eq $false)) 'Worker lost a failure receipt or dispatched a queued command.'
    $parameters.RequestsJson='[{"stepIndex":1,"command":"help","arguments":["-Topic","type"]},{"stepIndex":1,"command":"help","arguments":["-Topic",{"wrong":"object"}]}]'
    $invalid=Invoke-AGTAExplorationHost $run $parameters
    Check ($invalid.exitCode -eq 1 -and (Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl')).Count -eq 4) 'Worker partially dispatched an invalid batch.'
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1'
    $response=$request | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $run -RequestsStdin | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and $response.ok -and $response.explorationCommandId) 'Ordinary one-shot shell could not reach the warm worker.'
    $status=Invoke-AGTAExplorationHost $run @{Action='Status';RunRoot=$run}
    Check (($status.responses[0] | ConvertFrom-Json).commandCount -eq 5 -and $status.hostProcessId -eq $first.hostProcessId) 'Worker status disagreed with shell receipts.'
    $global:LASTEXITCODE=17
    $direct=& $entry -Action Batch -RunRoot $run -RequestsJson $request | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and $direct.ok -and $direct.explorationCommandId) 'Direct invocation leaked a previous native exit code.'
    Check ($direct.explorationTiming.clientMs -ge $direct.explorationTiming.hostMs -and $direct.explorationTiming.hostMs -ge $direct.totalDurationMs) 'Request timing did not bracket backend and receipt work.'
    $timing=Get-Content -LiteralPath (Join-Path $run 'logs\exploration-transport.jsonl') -Tail 1 | ConvertFrom-Json
    Check (-not $timing.hostStarted -and $timing.hostProcessId -eq $first.hostProcessId -and $timing.clientMs -ge 0 -and $timing.connectMs -ge 0) 'Transport log lost worker reuse or client/connection timing.'
    $unicode='Fixture '+[char]0x151+[char]0x4e2d
    $json=ConvertTo-Json -InputObject @(@{stepIndex=1;command='help';arguments=@('-Topic','type','-WindowSelectorJson',@{Name=$unicode;ClassName='#32770'})}) -Depth 8 -Compress
    $direct=& $entry -Action Batch -RunRoot $run -RequestsJson $json | ConvertFrom-Json
    $receipt=Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl') -Tail 1 | ConvertFrom-Json
    Check ($direct.ok -and ($receipt.arguments[3] | ConvertFrom-Json).Name -ceq $unicode) 'Direct JSON transport changed Unicode or nested object guards.'
    $failure=& $entry -Action Batch -RunRoot $run -RequestsJson '[{"stepIndex":1,"command":"help","arguments":["-Topic","missing"]}]' | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 1 -and -not $failure.ok -and $failure.explorationTiming) 'Direct invocation hid command failure or timing.'
    $direct=& $entry -Action Status -RunRoot $run | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and $direct.commandCount -eq 8) 'Direct success after failure retained failure exit state or lost receipts.'
    $lockedLog=[IO.File]::Open((Join-Path $run 'logs\exploration-transport.jsonl'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $direct=& $entry -Action Status -RunRoot $run | ConvertFrom-Json
        Check ($LASTEXITCODE -eq 0 -and $direct.ok -and $direct.explorationTiming.logError -and $direct.commandCount -eq 8) 'Diagnostic log failure hid an actual successful host response.'
    } finally {$lockedLog.Dispose()}
    $stopped=Invoke-AGTAExplorationHost $run @{} -Stop
    Check (($stopped.responses[0] | ConvertFrom-Json).hostStopped) 'StopHost did not acknowledge shutdown.'
    $notRunning=Invoke-AGTAExplorationHost $run @{} -Stop
    Check (-not ($notRunning.responses[0] | ConvertFrom-Json).hostStopped) 'StopHost started a new worker.'
    $idle=Join-Path $root 'idle';$runs+=,$idle
    Initialize-AGTAExploration $idle $csv GuiNavigation $cli | Out-Null
    $idleResponse=Invoke-AGTAExplorationHost $idle @{Action='Status';RunRoot=$idle} -IdleSeconds 1
    # Allow process teardown/scheduler latency beyond the one-second idle wait.
    $idleProcess=Get-Process -Id $idleResponse.hostProcessId -ErrorAction SilentlyContinue
    if ($idleProcess) {[void]$idleProcess.WaitForExit(4000);$idleProcess.Dispose()}
    Check (-not (Get-Process -Id $idleResponse.hostProcessId -ErrorAction SilentlyContinue)) 'Idle worker stayed alive past its bound.'
    $sealed=Join-Path $root 'sealed';$runs+=,$sealed
    Initialize-AGTAExploration $sealed $csv GuiNavigation $cli | Out-Null
    # Synthetic receipt fixtures validate transport sealing, not a user GUI task.
    Add-AGTAExplorationCommand $sealed 1 click @() @{ok=$true} | Out-Null
    $verification=Add-AGTAExplorationCommand $sealed 1 read @() @{ok=$true;data=@{text='Unit fixture'}}
    Complete-AGTAExplorationStep $sealed 1 'Unit fixture route' 'Unit fixture observation' $verification | Out-Null
    $complete=Invoke-AGTAExplorationHost $sealed @{Action='Complete';RunRoot=$sealed}
    Check ($complete.exitCode -eq 0 -and ($complete.responses[0] | ConvertFrom-Json).replayReferencePath) 'Worker failed to seal a completed fixture manifest.'
    $completeProcess=Get-Process -Id $complete.hostProcessId -ErrorAction SilentlyContinue
    if ($completeProcess) {[void]$completeProcess.WaitForExit(3000);$completeProcess.Dispose()}
    Check (-not (Get-Process -Id $complete.hostProcessId -ErrorAction SilentlyContinue)) 'Successful Complete left its worker running.'
    $cold=Join-Path $root 'cold';$warm=Join-Path $root 'warm';$runs+=,$warm
    foreach ($folder in @($cold,$warm)) {Initialize-AGTAExploration $folder $csv GuiNavigation $cli | Out-Null}
    $state='[{"stepIndex":1,"command":"state","arguments":[]}]'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    for ($i=0;$i -lt $Count;$i++) {
        $response=$state | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $cold -RequestsStdin -Transport InProcess | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $response.ok) {throw 'Cold benchmark request failed.'}
    }
    $coldMs=$watch.ElapsedMilliseconds;$watch.Restart()
    for ($i=0;$i -lt $Count;$i++) {
        $response=$state | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $warm -RequestsStdin | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $response.ok) {throw 'Worker benchmark request failed.'}
    }
    $warmMs=$watch.ElapsedMilliseconds
    $result=@{checks=$script:checks;requests=$Count;coldShellBatchesMs=$coldMs;reusedHostShellBatchesMs=$warmMs;
        note='Both modes use separate powershell.exe clients, real receipts and isolated CLI state. Warm measurement includes initial worker startup. Excludes agent/tool transport.'}
    if ($OutFile) {$result | ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8}
    $result | ConvertTo-Json -Compress
} finally {
    foreach ($run in $runs) {Invoke-AGTAExplorationHost $run @{} -Stop | Out-Null}
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-host-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
