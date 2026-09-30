param([int]$Count=10,[string]$OutFile)
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-benchmark-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
try {
    # Copy only the CLI implementation to isolate state/log writes from live sessions.
    $source=Join-Path (Split-Path -Parent $frameworkRoot) 'potato-cli'
    Copy-Item (Join-Path $source 'potato.ps1') $root
    Copy-Item (Join-Path $source 'commands.json') $root
    Copy-Item (Join-Path $source 'PoTAToCli') $root -Recurse
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Read fixture,,Fixture exists' | Set-Content $csv
    $fixture=Join-Path $root 'fixture.txt'; 'fixture' | Set-Content $fixture
    $measurements=@()
    foreach ($transport in @('Process','InProcess')) {
        $transportRoot=Join-Path $root $transport
        Initialize-AGTAExploration $transportRoot $csv GuiNavigation | Out-Null
        Add-AGTAExplorationCommand $transportRoot 1 focus @() @{ok=$true;interactionPolicy=@{mode='GuiNavigation'}} | Out-Null
        $receipt=Add-AGTAExplorationCommand $transportRoot 1 read @() @{ok=$true;data=@{text='Synthetic benchmark fixture'}}
        Complete-AGTAExplorationStep $transportRoot 1 'Synthetic fixture; no GUI benchmark' 'Fixture exists' $receipt | Out-Null
        Complete-AGTAExploration $transportRoot $csv GuiNavigation | Out-Null
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath (Join-Path $root 'potato.ps1') -TestCaseCsv $csv -RunRoot (Join-Path $root $transport) -Transport $transport
        for ($i=0;$i -lt $Count;$i++) {
            $r=Invoke-PotatoJson wait-file @('-Path',$fixture,'-TimeoutMs','0','-MinBytes','1')
            if (-not $r.ok -or -not $r.data.conditionMet) { throw 'Benchmark command failed.' }
        }
        $measurements += [pscustomobject]@{transport=$transport;count=$Count;elapsedMs=$watch.ElapsedMilliseconds;wrapperMs=$ctx.Timing.wrapperMs;backendMs=$ctx.Timing.backendMs}
    }
    $json=@{powershell=$PSVersionTable.PSVersion.ToString();command='wait-file existing fixture';policy='GuiNavigation';measurements=$measurements;note='Local transport microbenchmark; no GUI or end-to-end session speed claim.'} | ConvertTo-Json -Depth 5
    if ($OutFile) { $json | Set-Content -LiteralPath $OutFile -Encoding UTF8 }
    $json
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-benchmark-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
