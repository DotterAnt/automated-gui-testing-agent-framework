param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $frameworkRoot 'Framework\ReplaySession.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-replay-session-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0;$sessions=@()
function Check($condition,$message) {if (-not $condition) {throw $message};$script:checks++}
function Reject([scriptblock]$body,$message) {$caught=$null;try {& $body | Out-Null} catch {$caught=$_};Check ([bool]$caught) $message;return $caught}
function New-Plan($run,$body2) {
    $csv=Join-Path $run 'case.csv';[void][IO.Directory]::CreateDirectory($run)
    'Action,Data,Expected Result','First,,First','Second,,Second','Third,,Third' | Set-Content -LiteralPath $csv
    Initialize-AGTAExploration $run $csv GuiNavigation $cli | Out-Null
    $path=Join-Path $run 'generated.ps1'
    $source=@'
[CmdletBinding()]
param([string]$PotatoCliPath,[string]$TestCaseCsv,[string]$RunRoot,[string]$FrameworkRoot,[string]$ExplorationPath,[string]$InteractionPolicy='GuiNavigation',[string]$Transport='InProcess',[string]$OutputMode='Compact')
. (Join-Path $FrameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
Assert-AGTAGeneratedScriptPreflight -ScriptPath $PSCommandPath -TestCaseCsv $TestCaseCsv -PotatoCliPath $PotatoCliPath -ExplorationPath $ExplorationPath -InteractionPolicy $InteractionPolicy | Out-Null
$Context=Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot -ExplorationPath $ExplorationPath -InteractionPolicy $InteractionPolicy -Transport $Transport
$State=@{value=0}
$StepBodies=@(
    {param([ref]$Commands,[ref]$Evidence)
        $State.value++
        $clicked=Invoke-StepCommand $Commands click @('-Name','Fixture')
        Assert-PotatoOk $clicked
        $read=Invoke-StepCommand $Commands read @('-Name','Fixture')
        Assert-TextContains $read -Expected 'Fixture'
        Assert-ExpectedResult ($State.value -eq 1) 'State starts once'
    },
    BODY2,
    {param([ref]$Commands,[ref]$Evidence)
        $clicked=Invoke-StepCommand $Commands click @('-Name','Fixture')
        Assert-PotatoOk $clicked
        $read=Invoke-StepCommand $Commands read @('-Name','Fixture')
        Assert-TextContains $read -Expected 'Fixture'
        Assert-ExpectedResult ($State.value -eq 2) 'State survived'
    }
)
Invoke-AGTATestPlan -StepBodies $StepBodies -OutputMode $OutputMode
exit (Get-AGTATestExitCode)
'@
    $source.Replace('BODY2',$body2) | Set-Content -LiteralPath $path
    $path
}
function Install-Fixture($session) {
    & $session.module {
        function script:Invoke-EvidenceScreenshot {throw 'Fixture: desktop capture disabled.'}
        $script:AGTAGeneratedTestContext.CliModule=New-Module -ScriptBlock {
            function Invoke-PotatoCliCommand($Command,$Arguments,$CliRoot,[switch]$AsObject) {
                @{ok=$true;command=$Command;durationMs=0;data=@{text='Fixture';textSource='ValuePattern';clicked=$true};interactionPolicy=@{mode='GuiNavigation'}}
            }
        }
    }
}
function Record($session,$result) {
    Complete-AGTAExplorationStep $session.runRoot $result.stepIndex 'Fixture GUI route' 'Fixture reviewed' $result.verificationCommandIds | Out-Null
}
try {
    $cli=Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1'
    $good='{param([ref]$Commands,[ref]$Evidence) $State.value++; $clicked=Invoke-StepCommand $Commands click @("-Name","Fixture"); Assert-PotatoOk $clicked; $read=Invoke-StepCommand $Commands read @("-Name","Fixture"); Assert-TextContains $read -Expected "Fixture"; Assert-ExpectedResult ($State.value -eq 2) "State incremented"}'
    $bad='{param([ref]$Commands,[ref]$Evidence) throw "fixture failure"}'
    $run=Join-Path $root 'clean';$path=New-Plan $run $good
    Reject {Import-AGTAPlanSession $run $path Replay} 'Qualifying replay accepted incomplete exploration.' | Out-Null
    $session=Import-AGTAPlanSession $run $path;$sessions+=,$session;Install-Fixture $session
    Check ((& $session.module {$State.value}) -eq 0) 'Plan setup variables were lost or steps ran while loading.'
    Check ($session.context.RunKind -eq 'Diagnostic' -and $session.context.ResultPath -match 'diagnostic-') 'Development opened a canonical replay result.'
    foreach ($index in 1..3) {
        $result=Invoke-AGTAPlanStep $session
        Check ($result.ok -and $result.countsAsSuccessfulStep -and $result.status -eq 'FIRST_ATTEMPT_SUCCESS' -and $result.stepIndex -eq $index) ('First attempt was not retained as a successful step: '+$result.error)
        Record $session $result
    }
    Check ((& $session.module {$State.value}) -eq 2) 'Step execution restarted setup or previous bodies.'
    $final=Close-AGTAPlanSession $session | ConvertFrom-Json
    Check ($final.ok -and $final.qualifying -and $final.runKind -eq 'Replay' -and $final.summary.passed -eq 3) 'Unrepaired first-attempt session did not qualify without another replay.'
    Check ($final.artifacts.executionMode -eq 'IncrementalFirstAttempt' -and (& $session.module {$State.value}) -eq 2) 'Qualification secretly replayed steps.'
    Check ((Close-AGTAPlanSession $session | ConvertFrom-Json).executionId -eq $final.executionId) 'Repeated Close reran or overwrote qualification.'
    $journal=Get-Content $session.diagnosticResultPath -Raw | ConvertFrom-Json
    Check (-not $journal.qualifying -and $journal.attempts.Count -eq 3) 'Diagnostic journal was overwritten by the clean qualification.'
    $entries=@(Get-Content $session.context.CommandLogPath | ForEach-Object {$_ | ConvertFrom-Json})
    Check (@($entries | Where-Object {$_.command -in @('click','read')}).Count -eq 6 -and $entries[0].stepIndex -eq 1 -and $entries[0].PSObject.Properties.Name -notcontains 'raw') 'Logs duplicated envelopes or lost step identity.'
    $details=@(Get-AGTACommandDiagnostics $session.context.CommandLogPath -Last 1 -StepIndex 2)
    Check ($details.Count -eq 1 -and $details[0].command -eq 'read' -and $details[0].data.text -eq 'Fixture') 'Structured diagnostics lost actual readback or filtering.'
    (Get-Content $path -Raw).Replace('State starts once','Changed after qualification') | Set-Content $path
    Reject {Close-AGTAPlanSession $session} 'Close returned an old qualified result as proof of a changed script revision.' | Out-Null

    $run=Join-Path $root 'incremental';$pending='{param([ref]$Commands,[ref]$Evidence)}';$path=New-Plan $run $pending
    $session=Import-AGTAPlanSession $run $path;$sessions+=,$session;Install-Fixture $session
    $first=Invoke-AGTAPlanStep $session;Record $session $first
    Invoke-AGTAPlanRepair $session @(@{command='read';arguments=@('-Name','Fixture')}) | Out-Null
    (Get-Content $path -Raw).Replace($pending,$good) | Set-Content $path
    foreach ($index in 2..3) {$result=Invoke-AGTAPlanStep $session;Record $session $result}
    $final=Close-AGTAPlanSession $session | ConvertFrom-Json
    Check ($final.ok -and $final.qualifying -and (& $session.module {$State.value}) -eq 2) 'Developing pending bodies or read-only inspection forced a redundant full replay.'

    $run=Join-Path $root 'changed-prefix';$path=New-Plan $run $good
    $session=Import-AGTAPlanSession $run $path;$sessions+=,$session;Install-Fixture $session
    $first=Invoke-AGTAPlanStep $session;Record $session $first
    (Get-Content $path -Raw).Replace('State starts once','Changed previously executed body') | Set-Content $path
    foreach ($index in 2..3) {$result=Invoke-AGTAPlanStep $session;Record $session $result}
    $closed=Close-AGTAPlanSession $session
    Check (-not $closed.qualifying -and $session.tainted -and -not (Test-Path (Join-Path $run 'results\result.json'))) 'Modified previously executed code qualified without testing the final revision.'

    $run=Join-Path $root 'repair';$path=New-Plan $run $bad
    $session=Import-AGTAPlanSession $run $path;$sessions+=,$session;Install-Fixture $session
    $first=Invoke-AGTAPlanStep $session;Record $session $first
    $failure=Invoke-AGTAPlanStep $session
    Check (-not $failure.ok -and $session.nextStepIndex -eq 2 -and -not $session.closed) 'Failure closed/reset the application/session.'
    Reject {Invoke-AGTAPlanStep $session} 'Unreviewed failure accepted more input.' | Out-Null
    Get-AGTAPlanStatus $session | Out-Null
    (Get-Content $path -Raw).Replace($bad,$good) | Set-Content $path
    $retry=Invoke-AGTAPlanStep $session
    Check ($retry.ok -and $retry.status -eq 'RECOVERY_SUCCESS' -and -not $retry.countsAsSuccessfulStep) 'Recovery was confused with an original first-attempt pass.'
    Record $session $retry
    $third=Invoke-AGTAPlanStep $session;Record $session $third
    Check ($third.countsAsSuccessfulStep -and (& $session.module {$State.value}) -eq 2) 'Continuation reran the successful prefix or discarded first attempts.'
    $closed=Close-AGTAPlanSession $session
    Check ($closed.runKind -eq 'Diagnostic' -and -not $closed.qualifying -and -not (Test-Path (Join-Path $run 'results\result.json'))) 'Repaired session masqueraded as a full proper run.'
    $journal=Get-Content $session.diagnosticResultPath -Raw | ConvertFrom-Json
    Check ($journal.attempts.Count -eq 4 -and $journal.attempts[1].status -eq 'DIAGNOSTIC_FAILURE' -and $journal.attempts[2].status -eq 'RECOVERY_SUCCESS') 'Repair erased failed attempt history.'

    $run=Join-Path $root 'skip';$path=New-Plan $run $bad
    $session=Import-AGTAPlanSession $run $path;$sessions+=,$session;Install-Fixture $session
    Invoke-AGTAPlanStep $session | Out-Null;Invoke-AGTAPlanStep $session | Out-Null;Get-AGTAPlanStatus $session | Out-Null
    Reject {Skip-AGTAPlanStep $session ''} 'Skip accepted an unexplained bypass.' | Out-Null
    $skip=Skip-AGTAPlanStep $session 'Restored the application state live'
    Check ($skip.nextStepIndex -eq 3 -and $session.attempts[-1].status -eq 'BYPASSED') 'Skip invented a passed result.'
    (Get-Content $path -Raw).Replace('$State=@{value=0}','$State=@{value=99}') | Set-Content $path
    Reject {Invoke-AGTAPlanStep $session} 'Setup reload silently reset live variables.' | Out-Null
    $closed=Close-AGTAPlanSession $session
    Check ($session.closed -and $closed.updateError -match 'setup/helpers') 'Invalid edited setup prevented owned cleanup.'
    @{ok=$true;checks=$script:checks;psVersion=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress
} finally {
    foreach ($session in $sessions) {Remove-Module $session.module -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
