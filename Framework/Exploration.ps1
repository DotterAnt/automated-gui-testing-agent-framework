# Evidence-backed authoring checkpoint. This is an audit trail, not a sandbox.
function Get-AGTAExplorationPaths {
    param([string]$RunRoot)
    @{ manifest=(Join-Path $RunRoot 'logs\exploration.json'); transcript=(Join-Path $RunRoot 'logs\exploration-commands.jsonl') }
}

function Initialize-AGTAExploration {
    param([string]$RunRoot, [string]$TestCaseCsv, [string]$InteractionPolicy='GuiNavigation', [string]$PotatoCliPath)
    $RunRoot=[IO.Path]::GetFullPath($RunRoot)
    $paths=Get-AGTAExplorationPaths $RunRoot
    if (Test-Path -LiteralPath $paths.manifest) { throw 'Exploration already exists. Resume it or use a new run folder; do not overwrite evidence.' }
    $rows=@(Import-Csv -LiteralPath $TestCaseCsv)
    if (-not $rows.Count) { throw 'Exploration needs a nonempty testcase CSV.' }
    New-Item -ItemType Directory -Path (Split-Path $paths.manifest) -Force | Out-Null
    $value=[ordered]@{schemaVersion=1;testCasePath=(Get-Item -LiteralPath $TestCaseCsv).FullName;potatoCliPath=$PotatoCliPath;testCaseHash=(Get-FileHash -LiteralPath $TestCaseCsv -Algorithm SHA256).Hash;
        interactionPolicy=$InteractionPolicy;startedAt=(Get-Date).ToString('o');completedAt=$null;completed=$false;
        stepCount=$rows.Count;steps=@();transcriptPath=$paths.transcript;transcriptHash=$null}
    $value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $paths.manifest -Encoding UTF8
    $value
}

function Add-AGTAExplorationCommand {
    param([string]$RunRoot, [int]$StepIndex, [string]$Command, [string[]]$Arguments, $Result)
    $paths=Get-AGTAExplorationPaths $RunRoot
    $manifest=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    if ($manifest.completed) { throw 'Exploration is complete. Use normal runtime commands for execution.' }
    if ($StepIndex -lt 1 -or $StepIndex -gt $manifest.stepCount) { throw 'Exploration command requires a valid CSV StepIndex.' }
    $id=[guid]::NewGuid().ToString('N')
    $record=[ordered]@{id=$id;timestamp=(Get-Date).ToString('o');stepIndex=$StepIndex;command=$Command;arguments=@($Arguments);result=$Result}
    $record | ConvertTo-Json -Depth 80 -Compress | Add-Content -LiteralPath $paths.transcript -Encoding UTF8
    return $id
}

function Complete-AGTAExplorationStep {
    param([string]$RunRoot, [int]$StepIndex, [string]$Route, [string]$ObservedResult, [string]$VerificationCommandId)
    $paths=Get-AGTAExplorationPaths $RunRoot
    $manifest=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
    if ($manifest.completed) { throw 'Exploration is already complete.' }
    if ([string]::IsNullOrWhiteSpace($Route) -or [string]::IsNullOrWhiteSpace($ObservedResult)) { throw 'Record the performed GUI route and observed expected result, not a plan.' }
    $records=@(Get-Content -LiteralPath $paths.transcript | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.stepIndex -eq $StepIndex })
    $verification=@($records | Where-Object { $_.id -eq $VerificationCommandId })
    if ($verification.Count -ne 1) { throw 'VerificationCommandId must identify a recorded command from this CSV row.' }
    $v=$verification[0]
    if (-not $v.result.ok -or $v.command -notin @('read','select','observe','wait-element','wait-file','read-pdf','screenshot')) { throw 'Verification needs a successful observation command, not just action dispatch.' }
    if (($v.command -eq 'wait-element' -and -not $v.result.data.exists) -or
        ($v.command -eq 'wait-file' -and -not $v.result.data.conditionMet) -or
        ($v.command -eq 'select' -and $v.result.data.count -le 0)) { throw 'The recorded observation did not meet its postcondition.' }
    if ($v.command -eq 'screenshot' -and -not (Test-Path -LiteralPath $v.result.data.path -PathType Leaf)) { throw 'Screenshot evidence is missing.' }
    $actions=@($records | Where-Object { $_.result.ok -and $_.command -in @('start','focus','click','click-coordinate','type','press-key','hotkey','drag','close-window') -and $_.timestamp -le $v.timestamp })
    if (-not $actions.Count) { throw 'Perform the row through the GUI before recording its observation.' }
    $manifest.steps=@($manifest.steps | Where-Object { $_.stepIndex -ne $StepIndex }) + @([pscustomobject]@{
        stepIndex=$StepIndex;route=$Route;observedResult=$ObservedResult;verificationCommandId=$VerificationCommandId;commandIds=@($records.id);recordedAt=(Get-Date).ToString('o')})
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
        if ($live -and $live.MainWindowHandle -ne [IntPtr]::Zero) { throw 'An exploration-owned application window is still open. Close it through the GUI and verify cleanup before completing the walkthrough.' }
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
            successfulCommands=@($commands | Where-Object { Test-AGTAExplorationCommandSucceeded $_.result $_.command } | ForEach-Object {
                [ordered]@{id=$_.id;command=$_.command;arguments=$_.arguments;action=$_.result.data.action}
            });failedCommandIds=@($commands | Where-Object { -not (Test-AGTAExplorationCommandSucceeded $_.result $_.command) } | ForEach-Object {$_.id})}
    })
    @{note='Reference only, not a generated test. Preserve tested action arguments; discard irrelevant discovery and add real assertions. New selector constraints/routes need GUI validation.';steps=$routes} | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $routesPath -Encoding UTF8
    @{ok=$true;explorationPath=$paths.manifest;routesPath=$routesPath;covered=$manifest.stepCount}
}

function Test-AGTAExplorationCommandSucceeded {
    param($Result, [string]$Command)
    return [bool]($Result.ok -and -not (
        ($Command -eq 'wait-element' -and -not $Result.data.exists) -or
        ($Command -eq 'wait-file' -and -not $Result.data.conditionMet)))
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
        transcriptPath=$paths.transcript;explorationPath=$paths.manifest}
}

function Test-AGTAExploration {
    param([string]$Path, [string]$TestCaseCsv, [string]$InteractionPolicy)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Completed exploration manifest is required. Use Invoke-Exploration.ps1 for every CSV row before generating the script.' }
        $m=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($m.schemaVersion -ne 1) { throw 'Unsupported exploration manifest version.' }
        if (-not $m.completed -or -not $m.completedAt) { throw 'Exploration is incomplete.' }
        if ($m.interactionPolicy -ne $InteractionPolicy) { throw 'Exploration and execution policies differ.' }
        if ($m.testCaseHash -ne (Get-FileHash -LiteralPath $TestCaseCsv -Algorithm SHA256).Hash) { throw 'Exploration belongs to a different testcase CSV.' }
        if ($m.transcriptHash -ne (Get-FileHash -LiteralPath $m.transcriptPath -Algorithm SHA256).Hash) { throw 'Exploration transcript changed after completion.' }
        $rows=@(Import-Csv -LiteralPath $TestCaseCsv)
        if ($m.stepCount -ne $rows.Count -or @($m.steps).Count -ne $rows.Count) { throw 'Exploration row coverage differs from the CSV.' }
        $records=@(Get-Content -LiteralPath $m.transcriptPath | ForEach-Object { $_ | ConvertFrom-Json })
        for ($i=1;$i -le $rows.Count;$i++) {
            $step=@($m.steps | Where-Object {$_.stepIndex -eq $i})
            if ($step.Count -ne 1 -or -not $step[0].route -or -not $step[0].observedResult) { throw "Exploration row $i is missing." }
            $v=@($records | Where-Object {$_.id -eq $step[0].verificationCommandId -and $_.stepIndex -eq $i -and $_.result.ok})
            if ($v.Count -ne 1) { throw "Exploration row $i has no successful verification receipt." }
        }
        return @{ok=$true;path=$Path;completedAt=$m.completedAt;issues=@()}
    } catch { return @{ok=$false;path=$Path;issues=@($_.Exception.Message)} }
}
