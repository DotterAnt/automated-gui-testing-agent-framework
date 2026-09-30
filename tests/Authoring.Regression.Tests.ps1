param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-authoring-'+[guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$script:checks=0
function Check($value,$message) { if (-not $value) { throw $message }; $script:checks++ }
function Reject([scriptblock]$body,$message) { $caught=$false; try { & $body | Out-Null } catch { $caught=$true }; Check $caught $message }
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Create fixture,,Visible fixture','Reopen fixture,,Persisted fixture' | Set-Content $csv
    $initialized=Initialize-AGTAExploration $root $csv GuiNavigation
    Check ([IO.Directory]::Exists($initialized.explorationEvidenceRoot) -and @(Get-ChildItem -LiteralPath $initialized.explorationEvidenceRoot).Count -eq 0) 'Exploration did not prepare an empty output directory.'
    Push-Location $root
    try {
        $relative=Initialize-AGTAExploration '.\relative [folder]' $csv GuiNavigation
        Check ($relative.explorationEvidenceRoot -eq (Join-Path $root 'relative [folder]\evidence\exploration') -and [IO.Directory]::Exists($relative.explorationEvidenceRoot)) 'Relative exploration output root did not follow the PowerShell location or literal directory name.'
    } finally { Pop-Location }
    Reject { Complete-AGTAExploration $root $csv GuiNavigation } 'Empty exploration passed.'
    Reject { Complete-AGTAExplorationStep $root 1 'route' 'result' 'fabricated-id' } 'Invented evidence passed.'
    Check (Get-AGTAExplorationVerificationInfo @{command='windows';result=@{ok=$true;data=@{count=1}}}).eligible 'Window observation was rejected as evidence.'
    Check (-not (Get-AGTAExplorationVerificationInfo @{command='windows';result=@{ok=$true;data=@{count=0}}}).eligible) 'Empty window observation was accepted as evidence.'
    Check (-not (Get-AGTAExplorationVerificationInfo @{command='type';result=@{ok=$true;data=@{typed=$true;inputFocus=@{source='Win32';native=@{ready=$true}}}}}).eligible) 'Native focus readiness was confused with content verification.'
    $observation=Add-AGTAExplorationCommand $root 1 observe @('-Depth','3') @{ok=$true;data=@{elements=@()}}
    $receipt=Get-Content (Get-AGTAExplorationPaths $root).transcript -Tail 1 | ConvertFrom-Json
    Check ($receipt.id -eq $observation -and $receipt.arguments -contains 'Compact') 'Exploration receipt lost the shared observation default.'
    $values=@(Resolve-AGTACommandArguments observe @('-Format=Full'))
    Check ($values.Count -eq 1 -and $values[0] -eq '-Format=Full') 'Shared argument normalization overwrote explicit format syntax.'
    $plain=Add-AGTAExplorationCommand $root 1 type @('-Text','fixture') @{ok=$true;data=@{typed=$true;verificationPerformed=$false}}
    Reject { Complete-AGTAExplorationStep $root 1 'Typed fixture' 'Unverified text' $plain } 'Unverified typing passed as evidence.'
    $verified=Add-AGTAExplorationCommand $root 1 type @('-Text','fixture','-Verify') @{ok=$true;data=@{typed=$true;verificationPerformed=$true;verified=$true;verification=@{verified=$true;mode='Exact';attempts=1;observedLength=7;readError=$null}}}
    Complete-AGTAExplorationStep $root 1 'Typed fixture' 'Verified literal text' $verified | Out-Null
    Check ((Get-AGTAExplorationStatus $root).covered -eq 1) 'Successful type readback was rejected as evidence.'
    for ($i=1;$i -le 2;$i++) {
        Add-AGTAExplorationCommand $root $i click @('-Name','Fixture') @{ok=$true;interactionPolicy=@{mode='GuiNavigation'}} | Out-Null
        $miss=Add-AGTAExplorationCommand $root $i wait-element @() @{ok=$true;data=@{exists=$false}}
        Reject { Complete-AGTAExplorationStep $root $i 'Performed route' 'Not there' $miss } 'Successful dispatch of a failed wait passed.'
        $id=Add-AGTAExplorationCommand $root $i read @('-Name','Fixture') @{ok=$true;data=@{text='Observed fixture'}}
        Complete-AGTAExplorationStep $root $i 'Performed visible route' 'Observed fixture' $id | Out-Null
        if ($i -eq 1) { Reject { Complete-AGTAExploration $root $csv GuiNavigation } 'Partial coverage passed.' }
    }
    $completed=Complete-AGTAExploration $root $csv GuiNavigation
    Check (Test-AGTAExploration $completed.explorationPath $csv GuiNavigation).ok 'Complete exploration failed.'
    $savedManifest=Get-Content $completed.explorationPath -Raw
    $modified=$savedManifest | ConvertFrom-Json
    $modified.steps[0].verificationCommandId=$verified
    $modified | ConvertTo-Json -Depth 16 | Set-Content $completed.explorationPath
    Check (Test-AGTAExploration $completed.explorationPath $csv GuiNavigation).ok 'Execution gate rejected verified typing receipt.'
    $modified.steps[0].verificationCommandId=$plain
    $modified | ConvertTo-Json -Depth 16 | Set-Content $completed.explorationPath
    Check (-not (Test-AGTAExploration $completed.explorationPath $csv GuiNavigation).ok) 'Execution gate accepted unverified typing receipt.'
    $savedManifest | Set-Content $completed.explorationPath
    $routes=Get-Content -LiteralPath $completed.routesPath -Raw | ConvertFrom-Json
    Check ($routes.steps.Count -eq 2 -and $routes.steps[0].successfulCommands.Count -eq 5 -and $routes.steps[0].failedCommandIds.Count -eq 1) 'Route reference lost row coverage or included an unmet wait as successful.'
    Check (-not (Test-AGTAExploration $completed.explorationPath $csv VisibleControls).ok) 'Policy mismatch passed.'
    Reject { Add-AGTAExplorationCommand $root 1 click @() @{ok=$true} } 'Completed transcript was silently extended.'
    $scriptPath=Join-Path $root 'fixture.ps1'
    'Write-Output "Fixture"' | Set-Content $scriptPath
    Check (-not (Test-AGTAGeneratedScript $scriptPath -TestCaseCsv $csv).ok) 'Script without exploration passed full preflight.'
    Check (Test-AGTAGeneratedScript $scriptPath -TestCaseCsv $csv -ExplorationPath $completed.explorationPath).ok 'Evidence-backed harmless script failed preflight.'
    '{}' | Add-Content (Get-AGTAExplorationPaths $root).transcript
    Check (-not (Test-AGTAExploration $completed.explorationPath $csv GuiNavigation).ok) 'Altered transcript passed.'
    foreach ($code in @(
        'New-Object -ComObject Example.Application',
        '[Runtime.InteropServices.Marshal]::GetActiveObject("Example.Application")',
        '[Windows.Forms.SendKeys]::SendWait("text")',
        'Add-Type -Path "private-input.cs"',
        '$command.ExecuteNonQuery()',
        '$child = "$command.ExecuteNonQuery()"',
        'New-Object System.Drawing.Printing.PrintDocument',
        '$pdf = "%PDF-1.4"',
        'Start-Process "expected.document"',
        'Set-Clipboard "text"'
    )) {
        $code | Set-Content $scriptPath
        Check (-not (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok) "GUI bypass survived: $code"
    }
    # Existing testdata and read-only assertions remain legal.
    'Assert-ExpectedResult -Condition ($text -eq "Test") -Message "Persisted text"' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Read-only content assertion was blocked.'
    'Invoke-StepCommand -Commands $Commands -Command type -Arguments @("-Text", "INSERT INTO Records VALUES (1)")' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Literal SQL text typed through the GUI was confused with a database mutation.'
    # The runtime must catch the bypass even if standalone preflight is omitted.
    $runtime=Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1'
    $cli=Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1'
    @'
param($Runtime,$Cli,$Csv,$Root)
. $Runtime
$ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $Cli -TestCaseCsv $Csv -RunRoot $Root
$app=New-Object -ComObject Example.Application
'@ | Set-Content $scriptPath
    $ErrorActionPreference='Continue'
    $child=& powershell.exe -NoProfile -File $scriptPath -Runtime $runtime -Cli $cli -Csv $csv -Root $root 2>&1
    $ErrorActionPreference='Stop'
    Check ($LASTEXITCODE -ne 0 -and ($child -join "`n") -match 'audit failed before desktop use') 'Runtime did not stop the bypass before COM activation.'
    $batchRoot=Join-Path $root 'batch'
    Initialize-AGTAExploration $batchRoot $csv GuiNavigation | Out-Null
    $requests=Join-Path $root 'requests.json'
    @(@{stepIndex=1;command='help';arguments=@('-Topic','missing')},@{stepIndex=1;command='help';arguments=@('-Topic','type')}) | ConvertTo-Json -Depth 6 | Set-Content $requests
    $batch=@(& powershell.exe -NoProfile -File (Join-Path $frameworkRoot 'Invoke-Exploration.ps1') -Action Batch -RunRoot $batchRoot -TestCaseCsv $csv -PotatoCliPath $cli -RequestsPath $requests | ForEach-Object { $_ | ConvertFrom-Json })
    Check ($LASTEXITCODE -eq 1 -and $batch.Count -eq 1 -and $batch[0].explorationCommandId -and -not $batch[0].ok) ('Batch continued after a failed command or lost its receipt: '+($batch | ConvertTo-Json -Depth 5 -Compress))
    $requestsContent=@(@{stepIndex=1;command='help';arguments=@('-Topic','type')},@{stepIndex=1;command='help';arguments=@('-Topic','press-key')})
    $requestsContent | ConvertTo-Json -Depth 6 | Set-Content $requests
    $batch=@(& powershell.exe -NoProfile -File (Join-Path $frameworkRoot 'Invoke-Exploration.ps1') -Action Batch -RunRoot $batchRoot -TestCaseCsv $csv -PotatoCliPath $cli -RequestsPath $requests | ForEach-Object { $_ | ConvertFrom-Json })
    Check ($LASTEXITCODE -eq 0 -and $batch.Count -eq 2 -and $batch[0].ok -and $batch[1].ok -and $batch[0].explorationCommandId -ne $batch[1].explorationCommandId) 'Known sequential batch failed or reused receipt IDs.'
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1'
    $savedRoot=Join-Path $root 'saved configuration with spaces'
    $begin=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Begin -RunRoot $savedRoot -TestCaseCsv $csv -PotatoCliPath $cli -InteractionPolicy VisibleControls | ConvertFrom-Json
    Check ($begin.ok -and $begin.steps.Count -eq 2) 'Begin did not return the testcase context.'
    Check ($begin.explorationEvidenceRoot -eq (Join-Path $savedRoot 'evidence\exploration') -and [IO.Directory]::Exists($begin.explorationEvidenceRoot)) 'Begin did not return an existing absolute output folder.'
    $requestsContent | ConvertTo-Json -Depth 6 | Set-Content $requests
    $saved=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsPath $requests | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 0 -and $saved.Count -eq 2 -and $saved[0].ok) 'Batch lost persisted CSV/CLI/policy configuration.'
    $status=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Status -RunRoot $savedRoot | ConvertFrom-Json
    Check ($status.interactionPolicy -eq 'VisibleControls' -and $status.missingSteps.Count -eq 2 -and $status.commandCount -eq 2) 'Status hid missing rows or weakened the saved strict policy.'
    Check ($status.explorationEvidenceRoot -eq $begin.explorationEvidenceRoot -and $status.explorationEvidenceRootExists) 'Status lost the prepared output folder.'
    $oldOutputEncoding=$OutputEncoding
    $OutputEncoding=New-Object Text.UTF8Encoding($false)
    try {
        $stdin=@(($requestsContent | ConvertTo-Json -Depth 6) | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsStdin | ForEach-Object {$_ | ConvertFrom-Json})
        Check ($LASTEXITCODE -eq 0 -and $stdin.Count -eq 2 -and $stdin[1].ok) ('UTF-8 stdin batch lost commands or failed to record receipts: '+($stdin | ConvertTo-Json -Depth 4 -Compress))
        $unicode='missing-'+[char]0x151+[char]0x4e2d
        $badJson=@(@{stepIndex=1;command='help';arguments=@('-Topic',$unicode)},@{stepIndex=1;command='help';arguments=@()}) | ConvertTo-Json -Depth 6
        $bad=@($badJson | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsStdin | ForEach-Object {$_ | ConvertFrom-Json})
        Check ($LASTEXITCODE -eq 1 -and $bad.Count -eq 1 -and $bad[0].error.message.Contains($unicode)) 'Stdin corrupted Unicode or continued after failure.'
        $invalid='[{"stepIndex":1,"command":"help"},{"stepIndex":999,"command":"click"}]'
        $priorCount=(Get-AGTAExplorationStatus $savedRoot).commandCount
        $invalidResult=$invalid | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsStdin | ConvertFrom-Json
        Check (-not $invalidResult.ok -and (Get-AGTAExplorationStatus $savedRoot).commandCount -eq $priorCount) 'Invalid stdin batch dispatched a partial batch before validation.'
    } finally { $OutputEncoding=$oldOutputEncoding }
    @(@{stepIndex=1;command='type';arguments=@('-Text',(Join-Path $savedRoot 'missing\output.ext'),'-PathKind','SaveFile')},@{stepIndex=1;command='help';arguments=@()}) | ConvertTo-Json -Depth 6 | Set-Content $requests
    $badPath=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsPath $requests | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 1 -and $badPath.Count -eq 1 -and $badPath[0].error.type -eq 'PathValidationFailed' -and $badPath[0].outcome -eq 'not-dispatched' -and -not $badPath[0].verification.eligible) 'Batch continued after an invalid filename path or treated it as verified evidence.'
    $helperHelp=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Get-RuntimeHelp.ps1') -Names Invoke-StepCommand,Assert-TextContains | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and $helperHelp.Count -eq 2 -and $helperHelp[1].name -eq 'Assert-TextContains') 'Combined runtime help lost a requested signature.'
    $changed=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsPath $requests -InteractionPolicy GuiNavigation | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 1 -and -not $changed.ok) 'Persisted policy accepted a changed command policy.'
    @(@{stepIndex=1;command='wait-file';arguments=@('-Path',(Join-Path $root 'absent'),'-TimeoutMs','0')},@{stepIndex=1;command='help';arguments=@()}) | ConvertTo-Json -Depth 6 | Set-Content $requests
    $missed=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsPath $requests | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 1 -and $missed.Count -eq 1 -and $missed[0].ok -and -not $missed[0].data.conditionMet) 'Batch continued after unmet wait or changed CLI dispatch semantics.'
    Check (-not $missed[0].verification.eligible -and $missed[0].verification.note) 'Command response did not explain receipt ineligibility.'
    $reviewed=@()
    for ($i=1;$i -le 2;$i++) {
        Add-AGTAExplorationCommand $savedRoot $i click @('-Name','Synthetic fixture') @{ok=$true} | Out-Null
        $receipt=Add-AGTAExplorationCommand $savedRoot $i read @('-Name','Synthetic fixture') @{ok=$true;data=@{text='Synthetic fixture'}}
        $reviewed+=@{stepIndex=$i;route='Synthetic fixture route';observedResult='Synthetic fixture';verificationCommandId=$receipt}
    }
    $windowReceipt=Add-AGTAExplorationCommand $savedRoot 1 windows @('-Name','Synthetic fixture') @{ok=$true;data=@{count=1;windows=@(@{name='Synthetic fixture'})}}
    $reviewed[0].verificationCommandIds=@($reviewed[0].verificationCommandId,$windowReceipt)
    $reviewed | ConvertTo-Json -Depth 6 | Set-Content $requests
    $recorded=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action RecordSteps -RunRoot $savedRoot -RequestsPath $requests | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 0 -and $recorded.Count -eq 2 -and $recorded[1].covered -eq 2) 'Reviewed rows were not recorded in one invocation.'
    $composite=Get-AGTAExplorationStatus $savedRoot
    Check ($composite.steps[0].verificationCommandIds.Count -eq 2) 'Composite row evidence lost an observation.'
    Reject { Complete-AGTAExplorationStep $savedRoot 1 'Synthetic route' 'Invalid extra receipt' -VerificationCommandIds @($windowReceipt,'missing') } 'Invalid secondary receipt was ignored.'
    $compositeDone=Complete-AGTAExploration $savedRoot $csv VisibleControls
    Check (Test-AGTAExploration $compositeDone.explorationPath $csv VisibleControls).ok 'Composite evidence failed execution validation.'
    # Continue exercising RecordSteps on a still-open synthetic walkthrough.
    $compositeManifest=Get-Content $compositeDone.explorationPath -Raw | ConvertFrom-Json
    $compositeManifest.completed=$false; $compositeManifest.completedAt=$null; $compositeManifest.transcriptHash=$null
    $compositeManifest | ConvertTo-Json -Depth 16 | Set-Content $compositeDone.explorationPath
    $reviewed[0].observedResult='Observed '+[char]0x151+[char]0x4e2d
    $oldOutputEncoding=$OutputEncoding
    $OutputEncoding=New-Object Text.UTF8Encoding($false)
    try {
        $recorded=@(($reviewed | ConvertTo-Json -Depth 6) | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action RecordSteps -RunRoot $savedRoot -RequestsStdin | ForEach-Object {$_ | ConvertFrom-Json})
        $savedStatus=Get-AGTAExplorationStatus $savedRoot
        Check ($LASTEXITCODE -eq 0 -and $recorded.Count -eq 2 -and $savedStatus.steps[0].observedResult -ceq $reviewed[0].observedResult) 'Reviewed stdin rows corrupted Unicode or lost evidence.'
    } finally { $OutputEncoding=$oldOutputEncoding }
    Import-Module (Join-Path $frameworkRoot 'Framework\AutomatedGuiTestingAgentFramework.psm1') -Force
    $apiRoot=Join-Path $root 'api'
    $generated=Join-Path $apiRoot 'generated'; New-Item -ItemType Directory $generated -Force | Out-Null
    $context=[pscustomobject]@{TestCaseCsv=$csv;Steps=@(Import-Csv $csv);InteractionPolicy='GuiNavigation';PotatoCliPath=$cli;Execute=$true;Run=@{runRoot=$apiRoot;logs=(Join-Path $apiRoot 'logs');generated=$generated}}
    Invoke-AGTAAgentTool set_authoring_stage @{stage='planning';summary='Fixture plan'} $context | Out-Null
    $apiStage=Invoke-AGTAAgentTool set_authoring_stage @{stage='exploration';summary='Fixture walkthrough'} $context
    Check ($apiStage.explorationEvidenceRootExists -and [IO.Directory]::Exists($apiStage.explorationEvidenceRoot)) 'API exploration did not expose an existing output folder.'
    Reject { Invoke-AGTAAgentTool set_authoring_stage @{stage='development_iteration';summary='Too early'} $context } 'API stage advanced without exploration.'
    for ($i=1;$i -le 2;$i++) {
        Add-AGTAExplorationCommand $apiRoot $i click @() @{ok=$true} | Out-Null
        $id=Add-AGTAExplorationCommand $apiRoot $i read @() @{ok=$true;data=@{text='Synthetic observation'}}
        Invoke-AGTAAgentTool record_exploration_step @{stepIndex=$i;route='Synthetic fixture route';observedResult='Synthetic observation';verificationCommandId=$id} $context | Out-Null
    }
    Invoke-AGTAAgentTool set_authoring_stage @{stage='development_iteration';summary='Complete synthetic fixture'} $context | Out-Null
    $written=Invoke-AGTAAgentTool write_generated_script @{relativePath='fixture.ps1';content='Write-Output "fixture"'} $context
    Check (Test-Path $written.path) 'API did not write after complete exploration.'
    Reject { Invoke-AGTAAgentTool finalize @{scriptPath=$written.path;summary='Missing execution'} $context } 'API finalized without a passing execution.'
    $context | Add-Member LastExecution @{ok=$true;path=$written.path;hash=(Get-FileHash $written.path).Hash}
    Check (Invoke-AGTAAgentTool finalize @{scriptPath=$written.path;summary='Synthetic execution fixture'} $context).final 'API rejected an unchanged validated artifact.'
    'Write-Output "changed"' | Set-Content $written.path
    Reject { Invoke-AGTAAgentTool finalize @{scriptPath=$written.path;summary='Stale validation'} $context } 'API accepted stale execution evidence after a script change.'
    "Authoring checks: $script:checks passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-authoring-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
