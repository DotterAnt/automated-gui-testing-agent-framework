[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Begin','Command','Batch','RecordStep','RecordSteps','Status','Complete','StopHost')] [string]$Action,
    [Parameter(Mandatory)] [string]$RunRoot,
    [string]$TestCaseCsv,
    [string]$PotatoCliPath,
    [ValidateSet('GuiNavigation','VisibleControls','AllowShortcuts')] [string]$InteractionPolicy,
    [string]$PolicyReason,
    [int]$StepIndex,
    [string]$Command,
    [object[]]$Arguments=@(),
    [string]$RequestsPath,
    [switch]$RequestsStdin,
    [string]$RequestsJson,
    [string]$Route,
    [string]$ObservedResult,
    [string]$VerificationCommandId,
    [string[]]$VerificationCommandIds=@(),
    [ValidateSet('Compact','Full')] [string]$OutputMode='Compact',
    [ValidateSet('Auto','InProcess')] [string]$Transport='Auto'
)
$ErrorActionPreference='Stop'
if ([Console]::InputEncoding.CodePage -ne 65001) { [Console]::InputEncoding=New-Object Text.UTF8Encoding($false) }
if ([Console]::OutputEncoding.CodePage -ne 65001) { [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false) }
function Read-Requests {
    if (@($RequestsStdin.IsPresent, [bool]$RequestsPath, [bool]$RequestsJson | Where-Object {$_}).Count -ne 1) { throw 'Provide exactly one of RequestsStdin, RequestsPath or RequestsJson.' }
    $raw=if ($RequestsStdin) { [Console]::In.ReadToEnd() } elseif ($RequestsPath) { Get-Content -LiteralPath $RequestsPath -Raw } else {$RequestsJson}
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Request JSON is empty; no action was dispatched.' }
    $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
}
function Write-Response($Result, [int]$ActiveStep=0, [string]$ActiveCommand, [bool]$IncludeWorkflow=$true) {
    $workflow=$null
    if ($IncludeWorkflow -or $OutputMode -eq 'Full') {
        $workflow=Get-AGTAExplorationWorkflow -RunRoot $RunRoot -StepIndex $ActiveStep -Result $Result -Command $ActiveCommand
        if ($Result -is [System.Collections.IDictionary]) { $Result['workflow']=$workflow }
        else { $Result | Add-Member -NotePropertyName workflow -NotePropertyValue $workflow -Force }
    }
    if ($OutputMode -eq 'Compact' -and $Result.explorationCommandId) {
        # Complete command results remain in the transcript; never truncate readback.
        $Result=[ordered]@{ok=$Result.ok;command=$Result.command;data=$Result.data;error=$Result.error;
            outcome=$Result.outcome;durationMs=$Result.durationMs;totalDurationMs=$Result.totalDurationMs;
            explorationCommandId=$Result.explorationCommandId;verification=$Result.verification}
        if ($workflow) {$Result.workflow=$workflow}
    }
    $Result | ConvertTo-Json -Depth 80 -Compress
}
try {
    $RunRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
    if ($Transport -eq 'Auto') {
        . (Join-Path $PSScriptRoot 'Framework\ExplorationHost.ps1')
        $parameters=@{}
        foreach ($key in $PSBoundParameters.Keys) {
            $value=$PSBoundParameters[$key]
            $parameters[$key]=if ($value -is [Management.Automation.SwitchParameter]) {$value.IsPresent} else {$value}
        }
        $parameters.RunRoot=$RunRoot
        foreach ($key in @('TestCaseCsv','PotatoCliPath','RequestsPath')) {
            if ($parameters[$key]) {$parameters[$key]=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters[$key])}
        }
        if ($RequestsStdin) {
            $parameters.RequestsJson=[Console]::In.ReadToEnd()
            $parameters.Remove('RequestsStdin')
            # Do not erase a conflicting original source; validation stays exact.
            if ($RequestsJson) {throw 'Provide exactly one of RequestsStdin, RequestsPath or RequestsJson.'}
        }
        $response=Invoke-AGTAExplorationHost -RunRoot $RunRoot -Parameters $parameters -Stop:($Action -eq 'StopHost')
        foreach ($line in $response.responses) {$line}
        if ($response.exitCode -ne 0) {exit 1}
        return
    }
    if ($Action -eq 'StopHost') {throw 'StopHost uses the default Auto transport; exploration remains resumable.'}
    Import-Module (Join-Path $PSScriptRoot 'Framework\AutomatedGuiTestingAgentFramework.psm1')
    $paths=Get-AGTAExplorationPaths $RunRoot
    if ($Action -ne 'Begin') {
        $m=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
        if (-not $TestCaseCsv) { $TestCaseCsv=$m.testCasePath }
        if (-not $PotatoCliPath) { $PotatoCliPath=$m.potatoCliPath }
        if (-not $InteractionPolicy) { $InteractionPolicy=$m.interactionPolicy }
        if (-not $TestCaseCsv -or $m.interactionPolicy -ne $InteractionPolicy -or $m.testCaseHash -ne (Get-FileHash -LiteralPath $TestCaseCsv).Hash) { throw 'Exploration CSV or policy differs; no action was dispatched. Older manifests require explicit TestCaseCsv.' }
    }
    if (-not $InteractionPolicy) { $InteractionPolicy='GuiNavigation' }
    if (-not $PotatoCliPath) { $PotatoCliPath=Resolve-AGTADefaultPotatoCliPath }
    if ($InteractionPolicy -eq 'AllowShortcuts' -and $Action -eq 'Begin' -and -not $PolicyReason) { throw 'AllowShortcuts requires the explicit user/testcase authorization in PolicyReason.' }
    switch ($Action) {
        Begin {
            if (-not $TestCaseCsv) { throw 'Begin requires TestCaseCsv.' }
            Initialize-AGTAExploration $RunRoot $TestCaseCsv $InteractionPolicy (Get-Item -LiteralPath $PotatoCliPath).FullName | Out-Null
            $result=@{ok=$true;runRoot=$RunRoot;explorationPath=$paths.manifest;explorationEvidenceRoot=$paths.evidenceRoot;steps=@(Import-Csv -LiteralPath $TestCaseCsv);
                next='Keep this RunRoot. Default Auto transport reuses a local host across ordinary shell calls; pipe UTF-8 JSON to Batch -RequestsStdin. Interactive stdin can instead retain Invoke-ExplorationStream.ps1. Use explorationEvidenceRoot for full GUI paths and type PathKind. RecordSteps after reviewing each row; close owned windows, Complete, generate and replay. Use Transport InProcess for debugging; StopHost leaves exploration resumable.'}
        }
        { $_ -in @('Command','Batch') } {
            if ($m.completed) { throw 'Exploration is complete; no action was dispatched.' }
            $requests=@([pscustomobject]@{stepIndex=$StepIndex;command=$Command;arguments=$Arguments})
            if ($Action -eq 'Batch') {
                $decoded=Read-Requests
                $requests=@($decoded)
            }
            if ($requests.Count -lt 1 -or $requests.Count -gt 20) { throw 'A known sequential batch must contain 1..20 commands.' }
            # Validate/normalize the whole batch before the first GUI action.
            # JSON objects are allowed only as values of *Json options, just as
            # in generated replays. A malformed later request dispatches nothing.
            foreach ($request in $requests) {
                if ($request.stepIndex -lt 1 -or $request.stepIndex -gt $m.stepCount -or -not $request.command) { throw 'Every command needs a valid stepIndex and command; no action was dispatched.' }
                $request.arguments=@(Resolve-AGTACommandArguments $request.command @($request.arguments))
            }
            $requestIndex=0
            foreach ($request in $requests) {
                $values=@($request.arguments)
                if ($OutputMode -eq 'Compact' -and $request.command -eq 'observe' -and -not @($values | Where-Object {$_ -match '^--?Format(?:=|$)'}).Count) { $values+=@('-Format','Compact') }
                $result=Invoke-AGTAPotatoJson -PotatoCliPath $PotatoCliPath -Command $request.command -Arguments $values -RunRoot $RunRoot -InteractionPolicy $InteractionPolicy
                $id=Add-AGTAExplorationCommand $RunRoot $request.stepIndex $request.command $values $result
                $result | Add-Member -NotePropertyName explorationCommandId -NotePropertyValue $id -Force
                $result | Add-Member -NotePropertyName verification -NotePropertyValue (Get-AGTAExplorationVerificationInfo @{command=$request.command;result=$result}) -Force
                $succeeded=Test-AGTAExplorationCommandSucceeded $result $request.command
                $requestIndex++
                Write-Response $result $request.stepIndex $request.command ($requestIndex -eq $requests.Count -or -not $succeeded)
                if (-not $succeeded) { exit 1 }
            }
            return
        }
        RecordStep { $result=Complete-AGTAExplorationStep $RunRoot $StepIndex $Route $ObservedResult $VerificationCommandId $VerificationCommandIds }
        RecordSteps {
            $decoded=Read-Requests
            foreach ($record in @($decoded)) {
                Write-Response (Complete-AGTAExplorationStep $RunRoot $record.stepIndex $record.route $record.observedResult $record.verificationCommandId $record.verificationCommandIds)
            }
            return
        }
        Status { $result=Get-AGTAExplorationStatus $RunRoot }
        Complete { $result=Complete-AGTAExploration $RunRoot $TestCaseCsv $InteractionPolicy }
    }
    Write-Response $result
    if ($result.ok -eq $false) { exit 1 }
} catch {
    $failure=@{ok=$false;error=$_.Exception.Message}
    # Preserve the original error even if no usable manifest exists yet.
    try { $failure.workflow=Get-AGTAExplorationWorkflow -RunRoot $RunRoot -Result $failure } catch { }
    $failure | ConvertTo-Json -Depth 10 -Compress
    exit 1
}
