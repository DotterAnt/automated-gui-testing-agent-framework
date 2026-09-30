param([int]$Count=5,[string]$OutFile)
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\Exploration.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-exploration-benchmark-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Fixture' | Set-Content $csv
    $cli=Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1'
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1'
    $single=Join-Path $root 'single'; $batch=Join-Path $root 'batch'
    Initialize-AGTAExploration $single $csv GuiNavigation | Out-Null
    Initialize-AGTAExploration $batch $csv GuiNavigation | Out-Null
    $watch=[Diagnostics.Stopwatch]::StartNew()
    for ($i=0;$i -lt $Count;$i++) {
        $r=& powershell.exe -NoProfile -File $entry -Action Command -RunRoot $single -TestCaseCsv $csv -PotatoCliPath $cli -StepIndex 1 -Command help | ConvertFrom-Json
        if (-not $r.ok -or -not $r.explorationCommandId) { throw 'Single exploration command failed.' }
    }
    $singleMs=$watch.ElapsedMilliseconds
    $requests=Join-Path $root 'requests.json'
    @(1..$Count | ForEach-Object { @{stepIndex=1;command='help';arguments=@()} }) | ConvertTo-Json -Depth 6 | Set-Content $requests
    $watch.Restart()
    $results=@(& powershell.exe -NoProfile -File $entry -Action Batch -RunRoot $batch -TestCaseCsv $csv -PotatoCliPath $cli -RequestsPath $requests | ForEach-Object { $_ | ConvertFrom-Json })
    $batchMs=$watch.ElapsedMilliseconds
    if ($LASTEXITCODE -ne 0 -or $results.Count -ne $Count -or @($results | Where-Object {-not $_.ok -or -not $_.explorationCommandId}).Count) { throw 'Exploration batch failed.' }
    $json=@{command='help';count=$Count;singleProcessPerCommandMs=$singleMs;oneSequentialBatchMs=$batchMs;note='Same commands and receipts, no GUI. Local shell/transport measurement; not an end-to-end session prediction.'} | ConvertTo-Json
    if ($OutFile) { $json | Set-Content -LiteralPath $OutFile -Encoding UTF8 }
    $json
} finally {
    $resolved=[IO.Path]::GetFullPath($root); $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-exploration-benchmark-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
