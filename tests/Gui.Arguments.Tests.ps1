param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $frameworkRoot 'Framework\ExplorationHost.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-gui-arguments-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$child=$null;$run=Join-Path $root 'run';$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
try {
    $cliRoot=Join-Path $root 'cli'
    [void][IO.Directory]::CreateDirectory($cliRoot)
    $source=Join-Path (Split-Path $frameworkRoot) 'potato-cli'
    Copy-Item -LiteralPath (Join-Path $source 'PoTAToCli') -Destination $cliRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $source 'potato.ps1'),(Join-Path $source 'commands.json') -Destination $cliRoot
    $cli=Join-Path $cliRoot 'potato.ps1'
    $title='AGTA argument fixture '+[guid]::NewGuid().ToString('N')
    $child=& (Join-Path $PSScriptRoot 'support\Start-ArgumentFixture.ps1') $root $title
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Focus fixture,,Fixture dialog visible' | Set-Content -LiteralPath $csv
    Initialize-AGTAExploration $run $csv GuiNavigation $cli | Out-Null
    $requests=ConvertTo-Json -InputObject @(
        @{stepIndex=1;command='focus';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000')},
        @{stepIndex=1;command='windows';arguments=@('-Foreground','-WindowTitle',$title,'-TimeoutMs','3000')}
    ) -Depth 10 -Compress
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1'
    $responses=@(& $entry -Action Batch -RunRoot $run -RequestsJson $requests -Transport InProcess | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($responses.Count -eq 2 -and $responses[1].ok -and $responses[1].data.count -eq 1) 'Fixture exploration could not establish foreground readiness.'
    Complete-AGTAExplorationStep $run 1 'Focused the actual fixture dialog' 'Exact foreground title/class observed' $responses[1].explorationCommandId | Out-Null
    Complete-AGTAExploration $run $csv GuiNavigation | Out-Null
    $context=Initialize-AGTAGeneratedTest -PotatoCliPath $cli -TestCaseCsv $csv -RunRoot $run
    $commands=@()
    $ready=Invoke-StepCommand ([ref]$commands) windows @('-Foreground','-WindowTitle',$title,'-TimeoutMs','1000')
    $guard=$ready.data.foregroundSelector
    $rootWait=Invoke-StepCommand ([ref]$commands) wait-element @('-Scope','ForegroundWindow','-WindowSelectorJson',$guard,
        '-FallbackReason','Actual generic fixture dialog','-FallbackEvidence',$responses[1].explorationCommandId,
        '-Name',$title,'-TimeoutMs','1000')
    Check ($rootWait.ok -and $rootWait.data.exists -and $rootWait.data.elements[0].name -eq $title) 'A name-only presence wait missed the actual guarded window root.'
    $path=Join-Path $root 'saved file.docx'
    $firstType=$true
    foreach ($value in @($guard,($guard | ConvertTo-Json -Compress))) {
        $typed=Invoke-StepCommand ([ref]$commands) type @('-Scope','ForegroundWindow','-WindowSelectorJson',$value,
            '-FallbackReason','Actual generic fixture dialog','-FallbackEvidence',$responses[1].explorationCommandId,
            '-AutomationId','Filename','-Text',$path,'-PathKind','SaveFile','-PreDelete','-Verify','-TimeoutMs','1000')
        Check ($typed.ok -and $typed.data.verified) 'Actual replay typing failed with a wrapped path or object/string guard.'
        Check ($typed.data.clearMethod -eq $(if ($firstType) {'AlreadyEmpty'} else {'Selection'})) 'Replacement did not skip an empty field or select nonempty text.'
        $firstType=$false
    }
    $wrong=[ordered]@{Name='Unrelated fixture';ClassName=$guard.ClassName;ProcessId=$guard.ProcessId}
    $blocked=Invoke-StepCommand ([ref]$commands) type @('-Scope','ForegroundWindow','-WindowSelectorJson',$wrong,
        '-FallbackReason','Negative fixture test','-FallbackEvidence',$responses[1].explorationCommandId,
        '-AutomationId','Filename','-Text','must not be sent','-TimeoutMs','0')
    Check (-not $blocked.ok -and $blocked.error.type -eq 'ScopeNotReady' -and $blocked.outcome -eq 'not-dispatched') 'Argument fix weakened the exact foreground guard.'
    $read=Invoke-StepCommand ([ref]$commands) read @('-Scope','ForegroundWindow','-WindowSelectorJson',$guard,
        '-FallbackReason','Actual generic fixture dialog','-FallbackEvidence',$responses[1].explorationCommandId,'-AutomationId','Filename','-TimeoutMs','1000')
    Check ($read.ok -and $read.data.text -ceq $path) 'Rejected guard changed the filename field.'
    $explore=Join-Path $root 'worker-exploration'
    Initialize-AGTAExploration $explore $csv GuiNavigation $cli | Out-Null
    $requests=ConvertTo-Json -InputObject @(@{stepIndex=1;command='type';arguments=@('-Scope','ForegroundWindow','-WindowSelectorJson',$guard,
        '-FallbackReason','Actual fixture dialog','-FallbackEvidence',$responses[1].explorationCommandId,
        '-AutomationId','Filename','-Text',$path,'-PathKind','SaveFile','-PreDelete','-Verify','-TimeoutMs','1000')}) -Depth 12 -Compress
    $response=& $entry -Action Batch -RunRoot $explore -RequestsJson $requests | ConvertFrom-Json
    Check ($response.ok -and $response.data.verified -and $response.explorationCommandId) 'Warm one-shot exploration failed actual scoped typing with an object guard.'
    & $entry -Action StopHost -RunRoot $explore | Out-Null
    "GUI argument checks: $script:checks passed"
} finally {
    if ($child -and -not $child.HasExited) {Stop-Process -Id $child.Id -ErrorAction SilentlyContinue}
    if ($explore) {Invoke-AGTAExplorationHost $explore @{} -Stop | Out-Null}
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-gui-arguments-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
