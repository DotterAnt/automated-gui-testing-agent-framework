param([ValidateRange(2,20)] [int]$Count=6,[string]$OutFile)
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\Exploration.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-stream-measure-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Fixture' | Set-Content -LiteralPath $csv
    $sourceCli=Join-Path (Split-Path $frameworkRoot) 'potato-cli'
    $isolatedCli=Join-Path $root 'cli'
    [void][IO.Directory]::CreateDirectory($isolatedCli)
    Copy-Item -LiteralPath (Join-Path $sourceCli 'PoTAToCli') -Destination $isolatedCli -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceCli 'potato.ps1'),(Join-Path $sourceCli 'commands.json') -Destination $isolatedCli
    $cli=Join-Path $isolatedCli 'potato.ps1'
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1'
    $single=Join-Path $root 'single';$stream=Join-Path $root 'stream';$batch=Join-Path $root 'batch'
    foreach ($run in @($single,$stream,$batch)) {Initialize-AGTAExploration $run $csv GuiNavigation $cli | Out-Null}
    $request='[{"stepIndex":1,"command":"state","arguments":[]}]'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    for ($i=0;$i -lt $Count;$i++) {
        $response=$request | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $single -RequestsStdin | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $response.ok -or -not $response.explorationCommandId) {throw 'Cold exploration failed'}
    }
    $singleMs=$watch.ElapsedMilliseconds
    $lines=@(1..$Count | ForEach-Object {'{"action":"Batch","requests":'+$request+'}'})+@('{"action":"Quit"}')
    $watch.Restart()
    $responses=@($lines | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Invoke-ExplorationStream.ps1') -RunRoot $stream | ForEach-Object {$_ | ConvertFrom-Json})
    $streamMs=$watch.ElapsedMilliseconds
    if ($LASTEXITCODE -ne 0 -or $responses.Count -ne $Count+1 -or @($responses | Where-Object {-not $_.ok}).Count) {throw 'Warm exploration failed'}
    $requests=ConvertTo-Json -InputObject @(1..$Count | ForEach-Object {@{stepIndex=1;command='state';arguments=@()}}) -Depth 5 -Compress
    $watch.Restart()
    $responses=@($requests | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $batch -RequestsStdin | ForEach-Object {$_ | ConvertFrom-Json})
    $batchMs=$watch.ElapsedMilliseconds
    if ($LASTEXITCODE -ne 0 -or $responses.Count -ne $Count -or @($responses | Where-Object {-not $_.ok}).Count) {throw 'Combined exploration failed'}
    $result=@{command='state';count=$Count;coldBatchesMs=$singleMs;persistentBatchesMs=$streamMs;oneCombinedBatchMs=$batchMs;
        note='Same receipt-backed read-only commands in isolated CLI state. Piped stream timing excludes agent thinking/interactive tool transport; not an application authoring benchmark.'}
    if ($OutFile) {$result | ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8}
    $result | ConvertTo-Json -Compress
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-stream-measure-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
