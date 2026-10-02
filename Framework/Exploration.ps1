# Evidence-backed authoring checkpoint. This is an audit trail, not a sandbox.
function ConvertTo-AGTACompactWindowData {
    param($Data)
    $result=[ordered]@{}
    if ($Data -is [Collections.IDictionary]) {foreach ($key in $Data.Keys) {$result[$key]=$Data[$key]}}
    else {foreach ($property in $Data.PSObject.Properties) {$result[$property.Name]=$property.Value}}
    $result.windows=@(foreach ($window in $Data.windows) {
        $item=[ordered]@{}
        foreach ($key in @('name','className','processId','processName','nativeWindowHandle','controlType','isEnabled','isOffscreen','boundingRectangle','supportedPatterns')) {
            $item[$key]=$window.$key
        }
        if ($window.automationId) {$item.automationId=$window.automationId}
        if ($window.isModal) {$item.isModal=$true}
        if ($window.identitySource) {$item.identitySource=$window.identitySource}
        if (@($window.propertyErrors).Count) {$item.propertyErrors=$window.propertyErrors}
        $item
    })
    return $result
}

function Resolve-AGTACommandArguments {
    param([string]$Command,[object[]]$Arguments=@(),[string]$InteractionPolicy)
    $values=@(for ($i=0;$i -lt $Arguments.Count;$i++) {
        $value=$Arguments[$i]
        if ($null -eq $value) { throw "Null CLI argument at index $i. No action was dispatched." }
        # Cmdlet output strings (Join-Path, ConvertTo-Json, etc.) can also test
        # as PSCustomObject because PowerShell attaches an ETS wrapper. Scalars
        # must be handled first so repeated normalization stays idempotent.
        if ($value -is [string] -or $value.GetType().IsValueType) { [string]$value }
        elseif ($value -is [Collections.IDictionary] -or $value -is [pscustomobject] -or $value -is [array]) {
            if ($i -eq 0 -or [string]$Arguments[$i-1] -notmatch '^--?[A-Za-z]+Json$') {
                throw "Structured CLI argument at index $i needs a preceding *Json option. No action was dispatched."
            }
            ConvertTo-Json -InputObject $value -Depth 30 -Compress
        } else { [string]$value }
    })
    if ($InteractionPolicy) {
        if (@($values | Where-Object {$_ -match '^--?InteractionPolicy(?:=|$)'}).Count) {throw 'Per-command InteractionPolicy overrides are forbidden. Preserve the declared run policy. No action was dispatched.'}
        $shortcut=$Command -eq 'hotkey'
        for ($i=0;$i -lt $values.Count;$i++) {
            if ($values[$i] -match '^--?ClearMethod(?:=(.*))?$') {
                $method=if ($Matches[1]) {$Matches[1]} elseif ($i+1 -lt $values.Count) {$values[$i+1]} else {''}
                if ($method -eq 'Shortcut') {$shortcut=$true}
            }
        }
        if ($shortcut -and $InteractionPolicy -ne 'AllowShortcuts') {throw "InteractionPolicy $InteractionPolicy forbids application shortcuts. Use observed menu/button routes; a fallback reason is not authorization. No action was dispatched."}
        if ($Command -eq 'press-key' -and $InteractionPolicy -eq 'VisibleControls') {throw 'InteractionPolicy VisibleControls forbids navigation keys. No action was dispatched.'}
    }
    if ($Command -eq 'observe' -and -not @($values | Where-Object {$_ -match '^--?Format(?:=|$)'}).Count) { $values+=@('-Format','Compact') }
    if ($Command -eq 'start') {
        $modes=@($values | Where-Object {$_ -match '^--?RequireNew(?:Process|Window)(?:=|$)'})
        if (-not $modes.Count) { $values+=@('-RequireNewWindow','true') }
        foreach ($option in $modes) {
            $position=[array]::IndexOf($values,$option)
            if ($option -match '=(?:false|0|no|off)$' -or ($position+1 -lt $values.Count -and $values[$position+1] -match '^(?:false|0|no|off)$')) { throw 'Framework start requires new-window or new-process ownership. Use focus for deliberate reuse; it does not claim the host process.' }
        }
    }
    return $values
}

function Get-AGTAExplorationPaths {
    param([string]$RunRoot)
    $RunRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
    @{ manifest=(Join-Path $RunRoot 'logs\exploration.json'); transcript=(Join-Path $RunRoot 'logs\exploration-commands.jsonl');
        evidenceRoot=(Join-Path $RunRoot 'evidence\exploration') }
}

function Initialize-AGTAExploration {
    param([string]$RunRoot, [string]$TestCaseCsv, [string]$InteractionPolicy='GuiNavigation', [string]$PotatoCliPath)
    $RunRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
    $paths=Get-AGTAExplorationPaths $RunRoot
    if (Test-Path -LiteralPath $paths.manifest) { throw 'Exploration already exists. Resume it or use a new run folder; do not overwrite evidence.' }
    $rows=@(Import-Csv -LiteralPath $TestCaseCsv)
    if (-not $rows.Count) { throw 'Exploration needs a nonempty testcase CSV.' }
    New-Item -ItemType Directory -Path (Split-Path $paths.manifest) -Force | Out-Null
    # Prepare infrastructure only. The application must create all testcase outputs through its GUI.
    [void][IO.Directory]::CreateDirectory($paths.evidenceRoot)
    $value=[ordered]@{schemaVersion=1;testCasePath=(Get-Item -LiteralPath $TestCaseCsv).FullName;potatoCliPath=$PotatoCliPath;testCaseHash=(Get-FileHash -LiteralPath $TestCaseCsv -Algorithm SHA256).Hash;
        interactionPolicy=$InteractionPolicy;startedAt=(Get-Date).ToString('o');completedAt=$null;completed=$false;
        stepCount=$rows.Count;steps=@();transcriptPath=$paths.transcript;transcriptHash=$null;explorationEvidenceRoot=$paths.evidenceRoot}
    $value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $paths.manifest -Encoding UTF8
    $value
}

function Add-AGTAExplorationCommand {
    param([string]$RunRoot, [int]$StepIndex, [string]$Command, [string[]]$Arguments, $Result)
    $Arguments=@(Resolve-AGTACommandArguments $Command $Arguments)
    $paths=Get-AGTAExplorationPaths $RunRoot
    $manifest=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    if ($manifest.completed) { throw 'Exploration is complete. Use normal runtime commands for execution.' }
    if ($StepIndex -lt 1 -or $StepIndex -gt $manifest.stepCount) { throw 'Exploration command requires a valid CSV StepIndex.' }
    $id=[guid]::NewGuid().ToString('N')
    $record=[ordered]@{id=$id;timestamp=(Get-Date).ToString('o');stepIndex=$StepIndex;command=$Command;arguments=@($Arguments);result=$Result}
    $record | ConvertTo-Json -Depth 80 -Compress | Add-Content -LiteralPath $paths.transcript -Encoding UTF8
    return $id
}

function Assert-AGTAExplorationVerification {
    param($Receipt)
    $v=$Receipt
    if (-not $v.result.ok) { throw 'Verification needs a successful command.' }
    if ($v.command -eq 'type') {
        $data=$v.result.data
        if (-not $data.verificationPerformed -or $data.verified -ne $true -or
            -not $data.verification -or $data.verification.verified -ne $true -or $data.verification.attempts -lt 1 -or
            $null -eq $data.verification.observedLength -or $data.verification.readError -or
            $data.verification.mode -notin @('Exact','Contains','NormalizedExact','NormalizedContains')) {
            throw 'Typing is evidence only with successful -Verify readback; input dispatch alone is not verification.'
        }
        return
    }
    if ($v.command -notin @('read','select','windows','observe','wait-element','wait-file','read-pdf','screenshot')) { throw 'Verification needs a successful observation command or verified typing, not just action dispatch.' }
    if (($v.command -eq 'wait-element' -and -not $v.result.data.exists) -or
        ($v.command -eq 'wait-file' -and -not $v.result.data.conditionMet) -or
        ($v.command -eq 'screenshot' -and $v.result.data.visualWait -and -not $v.result.data.visualWait.conditionMet) -or
        ($v.command -eq 'select' -and $v.result.data.count -le 0) -or
        ($v.command -eq 'windows' -and $(if ($v.result.data.waitForNotExists) {
            $v.result.data.conditionMet -ne $true -or $v.result.data.count -ne 0
        } else {$v.result.data.count -le 0}))) { throw 'The recorded observation did not meet its postcondition.' }
    if ($v.command -eq 'screenshot' -and -not (Test-Path -LiteralPath $v.result.data.path -PathType Leaf)) { throw 'Screenshot evidence is missing.' }
}

function Get-AGTAExplorationVerificationInfo {
    param($Receipt)
    try { Assert-AGTAExplorationVerification $Receipt; return @{eligible=$true} }
    catch { return @{eligible=$false;note=$_.Exception.Message} }
}

function Complete-AGTAExplorationStep {
    param([string]$RunRoot, [int]$StepIndex, [string]$Route, [string]$ObservedResult, [string]$VerificationCommandId, [string[]]$VerificationCommandIds=@())
    $paths=Get-AGTAExplorationPaths $RunRoot
    $manifest=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    if ($manifest.completed) { throw 'Exploration is already complete.' }
    if ([string]::IsNullOrWhiteSpace($Route) -or [string]::IsNullOrWhiteSpace($ObservedResult)) { throw 'Record the performed GUI route and observed expected result, not a plan.' }
    $records=@(Get-Content -LiteralPath $paths.transcript | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.stepIndex -eq $StepIndex })
    $ids=@(@($VerificationCommandId)+@($VerificationCommandIds) | Where-Object {$_} | Select-Object -Unique)
    if (-not $ids.Count) { throw 'Provide VerificationCommandId or VerificationCommandIds for the row observations.' }
    foreach ($id in $ids) {
        $verification=@($records | Where-Object { $_.id -eq $id })
        if ($verification.Count -ne 1) { throw 'Each verification ID must identify a recorded command from this CSV row.' }
        $v=$verification[0]
        Assert-AGTAExplorationVerification $v
        $actions=@($records | Where-Object { $_.result.ok -and $_.command -in @('start','focus','click','click-coordinate','type','press-key','hotkey','drag','close-window') -and $_.timestamp -le $v.timestamp })
        if (-not $actions.Count) {
            $laterActions=@($records | Where-Object {$_.result.ok -and $_.command -in @('start','focus','click','click-coordinate','type','press-key','hotkey','drag','close-window')})
            if ($laterActions.Count) {throw "Verification receipt $id for row $StepIndex precedes that row's successful GUI actions. Remove this early ID and use a later reviewed observation from the same row. Recording order is unrestricted; do not replay performed routes merely to record them in order."}
            throw "No successful GUI action was recorded for row $StepIndex before verification receipt $id. Perform the missing row and inspect its actual result before recording."
        }
    }
    $manifest.steps=@($manifest.steps | Where-Object { $_.stepIndex -ne $StepIndex }) + @([pscustomobject]@{
        stepIndex=$StepIndex;route=$Route;observedResult=$ObservedResult;verificationCommandId=$ids[0];verificationCommandIds=$ids;commandIds=@($records.id);recordedAt=(Get-Date).ToString('o')})
    $manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $paths.manifest -Encoding UTF8
    @{ok=$true;stepIndex=$StepIndex;covered=$manifest.steps.Count;required=$manifest.stepCount}
}

function Complete-AGTAExploration {
    param([string]$RunRoot, [string]$TestCaseCsv, [string]$InteractionPolicy)
    $paths=Get-AGTAExplorationPaths $RunRoot
    $manifest=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    if ($manifest.testCaseHash -ne (Get-FileHash -LiteralPath $TestCaseCsv -Algorithm SHA256).Hash -or $manifest.interactionPolicy -ne $InteractionPolicy) { throw 'Exploration CSV or policy changed; use a fresh run.' }
    for ($i=1;$i -le $manifest.stepCount;$i++) {
        if (@($manifest.steps | Where-Object { $_.stepIndex -eq $i }).Count -ne 1) { throw "Exploration incomplete: CSV row $i has no verified route. Do not generate a guessed script." }
    }
    $receipts=@(Get-Content -LiteralPath $paths.transcript | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($receipt in @($receipts | Where-Object { $_.command -eq 'start' -and $_.result.ok -and $_.result.data.ownedProcessId })) {
        $live=Get-Process -Id $receipt.result.data.ownedProcessId -ErrorAction SilentlyContinue
        if ($live -and (-not $receipt.result.data.ownedProcessStartTime -or $receipt.result.data.ownedProcessStartTime -eq $live.StartTime.ToUniversalTime().Ticks.ToString()) -and $live.MainWindowHandle -ne [IntPtr]::Zero) { throw 'An exploration-owned application window is still open. Close it through the GUI and verify cleanup before completing the walkthrough.' }
    }
    foreach ($receipt in @($receipts | Where-Object {$_.result.ok -and $_.result.data.ownedWindow})) {
        $cli=Import-Module (Join-Path (Split-Path $manifest.potatoCliPath) 'PoTAToCli\PoTAToCli.psm1') -PassThru
        $identity=$receipt.result.data.ownedWindow | ConvertTo-Json -Compress
        $remaining=& $cli {param($json,$root) Invoke-PotatoCliCommand windows @('-WindowIdentityJson',$json) -CliRoot $root -AsObject} $identity (Split-Path $manifest.potatoCliPath)
        if (-not $remaining.ok -or $remaining.data.count -gt 0) { throw 'An exploration-owned window is still open or could not be checked. Close that window through the GUI; do not terminate its shared host process.' }
    }
    $manifest.completed=$true
    $manifest.completedAt=(Get-Date).ToString('o')
    $manifest.transcriptHash=(Get-FileHash -LiteralPath $paths.transcript -Algorithm SHA256).Hash
    $manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $paths.manifest -Encoding UTF8
    $routesPath=Join-Path $RunRoot 'logs\exploration-routes.json'
    $routes=@(foreach ($step in ($manifest.steps | Sort-Object stepIndex)) {
        $commands=@($receipts | Where-Object { $_.stepIndex -eq $step.stepIndex })
        [ordered]@{stepIndex=$step.stepIndex;route=$step.route;observedResult=$step.observedResult;
            verificationCommandId=$step.verificationCommandId;
            verificationCommandIds=@($step.verificationCommandIds);
            successfulCommands=@($commands | Where-Object { Test-AGTAExplorationCommandSucceeded $_.result $_.command } | ForEach-Object {
                [ordered]@{id=$_.id;command=$_.command;arguments=$_.arguments;action=$_.result.data.action}
            });failedCommandIds=@($commands | Where-Object { -not (Test-AGTAExplorationCommandSucceeded $_.result $_.command) } | ForEach-Object {$_.id})}
    })
    @{note='Reference only, not a generated test. Preserve tested action arguments; discard irrelevant discovery and add real assertions. New selector constraints/routes need GUI validation.';steps=$routes} | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $routesPath -Encoding UTF8
    $referencePath=Join-Path $RunRoot 'logs\replay-reference.json'
    @{note='Reviewed route reference, not a replay script. Keep tested guards and assertions. Omit exploratory recovery actions that are unnecessary from the verified initial state.';
        replayRules=@('Preserve each CSV-specific menu route and expected content check; a convenient default action is not a substitute.',
            'Resolve PIDs, handles, checkpoints, foreground selectors and run output paths again in replay; exploration values are not stable identities.',
            'New GUI handoff: checkpoint before opening, then focus SinceCheckpoint to register its new window. Reused window: exact fresh foregroundSelector with WindowSelectorJson; plain focus does not grant cleanup ownership.',
            'First-run/import/already-present state may change during exploration. Probe optional controls without input; branch on actual state before mandatory actions.',
            'Opaque asynchronous controls: screenshot WaitForChangeFrom with an observed ChangeRegionJson can await changed/settled content without repeated input; preserve tested bounds/origin and assert conditionMet. Do not repeat clicks from immediate stale captures.',
            'Every content/layout expectation needs actual replay assertions. Screenshot existence, dimensions and PDF markers do not prove the image or absence of cropping.',
            'Runtime preflights each replay. After a repair, run the script directly; use one targeted read-only check for an unresolved argument/signature error instead of duplicate parse plus preflight calls.');
        steps=@($routes | ForEach-Object {
            $row=$_
            [ordered]@{stepIndex=$row.stepIndex;route=$row.route;observedResult=$row.observedResult;
                commands=@($row.successfulCommands | Where-Object {$_.command -in @('start','focus','click','click-coordinate','type','press-key','hotkey','drag','close-window','wait-element','wait-file') -or $_.id -in $row.verificationCommandIds} | ForEach-Object {
                    [ordered]@{command=$_.command;arguments=$_.arguments}
                })}
        })} | ConvertTo-Json -Depth 24 -Compress | Set-Content -LiteralPath $referencePath -Encoding UTF8
    @{ok=$true;explorationPath=$paths.manifest;routesPath=$routesPath;replayReferencePath=$referencePath;covered=$manifest.stepCount}
}

function Test-AGTAExplorationCommandSucceeded {
    param($Result, [string]$Command)
    return [bool]($Result.ok -and -not (
        ($Command -eq 'wait-element' -and -not $Result.data.exists) -or
        ($Command -eq 'windows' -and $Result.data.waitForNotExists -and ($Result.data.conditionMet -ne $true -or $Result.data.count -ne 0)) -or
        ($Command -eq 'wait-file' -and -not $Result.data.conditionMet) -or
        ($Command -eq 'screenshot' -and $Result.data.visualWait -and -not $Result.data.visualWait.conditionMet)))
}

function Get-AGTAExplorationWorkflow {
    param([string]$RunRoot, [int]$StepIndex, $Result, [string]$Command)
    # Keep progress cheap: never scan command transcripts or query the desktop here.
    $paths=Get-AGTAExplorationPaths $RunRoot
    $m=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    $missing=@(1..$m.stepCount | Where-Object {$_ -notin @($m.steps.stepIndex)})
    $next='Continue the missing CSV rows through the GUI. Review and record each verified row as you finish it; do not generate the script yet.'
    if ($m.completed) {
        $next='Exploration is complete, not the whole task. Generate the script, then execute and repair it until the delivered revision passes every row, required assertion and cleanup.'
    } elseif ($Command -in @('RecordStep','RecordSteps') -and $Result.ok -eq $false) {
        $next='Recording failed without dispatching GUI input. Correct the verification IDs using existing row receipts. Each ID must follow a successful action in that row; recording order is unrestricted. Repeat GUI work only when its actual expected result is missing.'
    } elseif ($Result -and -not (Test-AGTAExplorationCommandSucceeded $Result $Command)) {
        $next='Recover the failed command using observed GUI state, then resume this walkthrough. Do not replace unfinished rows with guessed script steps or deliver a partial result.'
    } elseif (-not $missing.Count) {
        $next='All rows are recorded. Close exploration-owned windows through the GUI, verify cleanup, then Complete and continue to script generation and execution.'
    } elseif ($StepIndex -in $missing -and $Result.verification.eligible) {
        $next='Review whether the observations prove every expectation of this row. If so, record it now; otherwise finish its missing actions and assertions. Continue the remaining rows.'
    }
    # This checkpoint cannot establish completion of the subsequent script execution.
    [ordered]@{stage=$(if ($m.completed) {'development_iteration'} else {'exploration'});
        explorationComplete=[bool]$m.completed;recorded=$m.steps.Count;required=$m.stepCount;
        missingSteps=$missing;nextAction=$next}
}

function Get-AGTAExplorationStatus {
    param([string]$RunRoot)
    $paths=Get-AGTAExplorationPaths $RunRoot
    $m=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    $receipts=@()
    if (Test-Path -LiteralPath $paths.transcript) { $receipts=@(Get-Content -LiteralPath $paths.transcript | ForEach-Object { $_ | ConvertFrom-Json }) }
    @{ok=$true;completed=$m.completed;interactionPolicy=$m.interactionPolicy;covered=$m.steps.Count;required=$m.stepCount;
        missingSteps=@(1..$m.stepCount | Where-Object {$_ -notin @($m.steps.stepIndex)});
        steps=$m.steps;commandCount=$receipts.Count;
        recentFailures=@($receipts | Where-Object {-not (Test-AGTAExplorationCommandSucceeded $_.result $_.command)} | Select-Object -Last 5 | ForEach-Object { @{id=$_.id;stepIndex=$_.stepIndex;command=$_.command;error=$_.result.error} });
        ownedProcessIds=@($receipts | Where-Object {$_.command -eq 'start' -and $_.result.ok} | ForEach-Object {$_.result.data.ownedProcessId});
        ownedWindows=@($receipts | Where-Object {$_.result.ok -and $_.result.data.ownedWindow} | ForEach-Object {$_.result.data.ownedWindow});
        transcriptPath=$paths.transcript;explorationPath=$paths.manifest;
        explorationEvidenceRoot=$paths.evidenceRoot;explorationEvidenceRootExists=[IO.Directory]::Exists($paths.evidenceRoot)}
}

function Test-AGTAExploration {
    param([string]$Path, [string]$TestCaseCsv, [string]$InteractionPolicy)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Completed exploration manifest is required. Use Invoke-Exploration.ps1 for every CSV row before generating the script.' }
        $m=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($m.schemaVersion -ne 1) { throw 'Unsupported exploration manifest version.' }
        if (-not $m.completed -or -not $m.completedAt) { throw 'Exploration is incomplete. Resume the existing walkthrough: use Status, finish and record every missing CSV row, then Complete before generating or executing. This is unfinished work, not a final-delivery result.' }
        if ($m.interactionPolicy -ne $InteractionPolicy) { throw 'Exploration and execution policies differ.' }
        if ($m.testCaseHash -ne (Get-FileHash -LiteralPath $TestCaseCsv -Algorithm SHA256).Hash) { throw 'Exploration belongs to a different testcase CSV.' }
        if ($m.transcriptHash -ne (Get-FileHash -LiteralPath $m.transcriptPath -Algorithm SHA256).Hash) { throw 'Exploration transcript changed after completion.' }
        $rows=@(Import-Csv -LiteralPath $TestCaseCsv)
        if ($m.stepCount -ne $rows.Count -or @($m.steps).Count -ne $rows.Count) { throw 'Exploration row coverage differs from the CSV.' }
        $records=@(Get-Content -LiteralPath $m.transcriptPath | ForEach-Object { $_ | ConvertFrom-Json })
        for ($i=1;$i -le $rows.Count;$i++) {
            $step=@($m.steps | Where-Object {$_.stepIndex -eq $i})
            if ($step.Count -ne 1 -or -not $step[0].route -or -not $step[0].observedResult) { throw "Exploration row $i is missing." }
            $ids=@(@($step[0].verificationCommandId)+@($step[0].verificationCommandIds) | Where-Object {$_} | Select-Object -Unique)
            if (-not $ids.Count) { throw "Exploration row $i has no verification receipt." }
            foreach ($id in $ids) {
                $v=@($records | Where-Object {$_.id -eq $id -and $_.stepIndex -eq $i -and $_.result.ok})
                if ($v.Count -ne 1) { throw "Exploration row $i has no successful verification receipt for $id." }
                Assert-AGTAExplorationVerification $v[0]
            }
        }
        return @{ok=$true;path=$Path;completedAt=$m.completedAt;issues=@()}
    } catch { return @{ok=$false;path=$Path;issues=@($_.Exception.Message)} }
}
