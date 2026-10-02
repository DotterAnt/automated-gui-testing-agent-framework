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
    $lateRoot=Join-Path $root 'late-recording'
    Initialize-AGTAExploration $lateRoot $csv GuiNavigation | Out-Null
    $early=Add-AGTAExplorationCommand $lateRoot 2 observe @() @{ok=$true;data=@{elements=@()}}
    # Explicit timestamp ordering avoids clock resolution flakiness.
    $earlyPath=(Get-AGTAExplorationPaths $lateRoot).transcript
    $earlyRecord=Get-Content $earlyPath -Raw | ConvertFrom-Json
    $earlyRecord.timestamp='2000-01-01T00:00:00Z'
    $earlyRecord | ConvertTo-Json -Depth 12 -Compress | Set-Content $earlyPath
    Add-AGTAExplorationCommand $lateRoot 2 click @() @{ok=$true} | Out-Null
    $later=Add-AGTAExplorationCommand $lateRoot 2 read @() @{ok=$true;data=@{text='Actual fixture content'}}
    $failure=$null;try {Complete-AGTAExplorationStep $lateRoot 2 'route' 'actual result' $early | Out-Null} catch {$failure=$_.Exception.Message}
    Check ($failure -match 'precedes' -and $failure -match 'order is unrestricted' -and $failure.Contains($early)) 'Early receipt failure was confused with recording order or omitted the offending ID.'
    Complete-AGTAExplorationStep $lateRoot 2 'route' 'actual result' $later | Out-Null
    Check ((Get-AGTAExplorationStatus $lateRoot).covered -eq 1) 'A reviewed later receipt required recording the prior row or replaying GUI work.'
    $workflow=Get-AGTAExplorationWorkflow $lateRoot -Result @{ok=$false} -Command RecordSteps
    Check ($workflow.nextAction -match 'without dispatching GUI input' -and $workflow.nextAction -match 'existing row receipts') 'Recording failure recommended replaying the GUI route.'
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
        '[System.Drawing.Graphics]::FromImage($bitmap)'
        '$graphics.DrawLine($pen,1,2,3,4)'
        '$python = "from PIL import ImageDraw; draw = ImageDraw.Draw(image)"'
        'Invoke-CimMethod -InputObject $device -MethodName SetDefaultPrinter'
        'Invoke-WmiMethod -Class Example -Name Mutate'
        'Set-CimInstance -InputObject $device -Property @{Enabled=$true}'
        'Set-Printer -Name "Example" -DriverName "Other"'
        '$device.SetDefaultPrinter()'
        'param([string]$InteractionPolicy="AllowShortcuts")'
        'param([string]$PolicyReason="The application exposes file actions through accelerators")'
        '$InteractionPolicy = "AllowShortcuts"'
        'Initialize-AGTAGeneratedTest -InteractionPolicy AllowShortcuts -PolicyReason "required file commands"'
        'Invoke-StepCommand -Commands $Commands -Command hotkey -Arguments @("-Keys","^o")'
    )) {
        $code | Set-Content $scriptPath
        Check (-not (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok) "GUI bypass survived: $code"
    }
    # Existing testdata and read-only assertions remain legal.
    foreach ($constant in @('$true','($true)','(($TRUE))')) {
        ('Assert-ExpectedResult -Condition '+$constant+' -Message "Rotated preview"') | Set-Content $scriptPath
        $audit=Test-AGTAGeneratedScript $scriptPath -PolicyOnly
        Check (-not $audit.ok -and ($audit.issues -join ' ') -match 'always passes') 'An unconditional passing assertion survived runtime preflight.'
    }
    'Assert-ExpectedResult -Condition:$true -Message "Preview"' | Set-Content $scriptPath
    Check (-not (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok) 'Inline unconditional passing assertion survived.'
    '$shot=Invoke-EvidenceScreenshot -Name "preview"; Assert-ExpectedResult -Condition (Test-Path -LiteralPath $shot) -Message "Rotated image"' | Set-Content $scriptPath
    $audit=Test-AGTAGeneratedScript $scriptPath -PolicyOnly
    Check (-not $audit.ok -and ($audit.issues -join ' ') -match 'screenshot existence') 'Screenshot existence was allowed to stand in for content verification.'
    '$shot=Join-Path $root "preview.png"; $r=Invoke-StepCommand -Commands $Commands -Command screenshot -Arguments @("-OutFile",$shot); Assert-ExpectedResult -Condition (Test-Path -LiteralPath $shot) -Message "Rotated image"' | Set-Content $scriptPath
    Check (-not (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok) 'Recorded screenshot output path was allowed to stand in for content verification.'
    '$shot=Invoke-EvidenceScreenshot -Name "preview"; Assert-ExpectedResult -Condition ((Test-Path -LiteralPath $shot) -and $measuredContentMatches) -Message "Actual content"' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Evidence existence combined with actual content verification was rejected.'
    'Assert-ExpectedResult -Condition (Test-Path -LiteralPath $savedFile) -Message "Saved file exists"' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Legitimate created-file existence assertion was blocked.'
    'Get-Content -LiteralPath $artifact -Encoding Latin1' | Set-Content $scriptPath
    $audit=Test-AGTAGeneratedScript $scriptPath -PolicyOnly
    Check ($audit.ok -eq ($PSVersionTable.PSVersion.Major -ge 6)) 'Literal shell-specific encoding did not match the active host compatibility.'
    'Assert-ImageRegionMatches -Path $image -ReferencePath $source -ReferenceRotation 45' | Set-Content $scriptPath
    Check (-not (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok) 'Unsupported literal helper rotation survived preflight.'
    'Get-Content -LiteralPath $artifact -Encoding UTF8' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Supported literal encoding was rejected.'
    'Assert-ExpectedResult -Condition ($text -eq "Test") -Message "Persisted text"' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Read-only content assertion was blocked.'
    'Get-CimInstance -ClassName Win32_Printer | Select-Object Name,Default' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Read-only system-state verification was blocked.'
    '$bitmap = [Drawing.Bitmap]::new($existingPath); $pixel = $bitmap.GetPixel(1,2); $bitmap.Dispose()' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Read-only image verification was confused with synthetic content generation.'
    'Invoke-StepCommand -Commands $Commands -Command type -Arguments @("-Text", "INSERT INTO Records VALUES (1)")' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Literal SQL text typed through the GUI was confused with a database mutation.'
    'param([string]$InteractionPolicy="GuiNavigation",[string]$PolicyReason="")' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly).ok 'Safe policy defaults were blocked.'
    'Invoke-StepCommand -Commands $Commands -Command hotkey -Arguments @("-Keys","^o")' | Set-Content $scriptPath
    Check (Test-AGTAGeneratedScript $scriptPath -PolicyOnly -InteractionPolicy AllowShortcuts).ok 'Explicit caller shortcut policy was removed.'
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
    @'
param($Runtime,$Cli,$Csv,$Root,[string]$InteractionPolicy='AllowShortcuts',[string]$PolicyReason='Required file actions use accelerators')
. $Runtime
$ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $Cli -TestCaseCsv $Csv -RunRoot $Root -InteractionPolicy $InteractionPolicy -PolicyReason $PolicyReason
throw 'Fixture runtime failed to stop the self-granted policy'
'@ | Set-Content $scriptPath
    $ErrorActionPreference='Continue'
    $child=& powershell.exe -NoProfile -File $scriptPath -Runtime $runtime -Cli $cli -Csv $csv -Root $root 2>&1
    $ErrorActionPreference='Stop'
    Check ($LASTEXITCODE -ne 0 -and ($child -join "`n") -match 'audit failed before desktop use' -and ($child -join "`n") -match 'script default') 'Omitting standalone preflight allowed a script to grant itself shortcut policy.'
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
    foreach ($policyRequest in @(
        @{stepIndex=1;command='hotkey';arguments=@('-Keys','^o','-FallbackReason','Required file command','-FallbackEvidence','fixture')},
        @{stepIndex=1;command='type';arguments=@('-Text','value','-PreDelete','-ClearMethod=Shortcut')},
        @{stepIndex=1;command='help';arguments=@('-InteractionPolicy','AllowShortcuts')}
    )) {
        $json=ConvertTo-Json -InputObject @(@{stepIndex=1;command='help';arguments=@('-Topic','click')},$policyRequest) -Depth 6 -Compress
        $blocked=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $savedRoot -RequestsJson $json | ForEach-Object {$_ | ConvertFrom-Json})
        Check ($LASTEXITCODE -eq 1 -and $blocked.Count -eq 1 -and -not $blocked[0].ok -and (Get-AGTAExplorationStatus $savedRoot).commandCount -eq 0) 'A later policy violation dispatched the earlier batch command.'
    }
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
    foreach ($wrapper in @('function Launch { return ''/c start "" "protocol:document" & timeout /t 60'' }', 'function Launch { return ''url.dll,FileProtocolHandler protocol:document'' }')) {
        $wrapperFile=Join-Path $root 'wrapper.ps1'
        Set-Content -LiteralPath $wrapperFile -Value $wrapper
        $assessment=Test-AGTAGeneratedScript -ScriptPath $wrapperFile -PolicyOnly
        Check (-not $assessment.ok -and ($assessment.issues -join ' ') -match 'shell/protocol launcher') 'Observed launcher workaround passed static audit.'
    }
    "Authoring checks: $script:checks passed"
} finally {
    . (Join-Path $frameworkRoot 'Framework\ExplorationHost.ps1')
    foreach ($folder in @($batchRoot,$savedRoot) | Where-Object {$_}) {Invoke-AGTAExplorationHost $folder @{} -Stop | Out-Null}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-authoring-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
