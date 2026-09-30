[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Begin','Command','Batch','RecordStep','RecordSteps','Status','Complete')] [string]$Action,
    [Parameter(Mandatory)] [string]$RunRoot,
    [string]$TestCaseCsv,
    [string]$PotatoCliPath,
    [ValidateSet('GuiNavigation','VisibleControls','AllowShortcuts')] [string]$InteractionPolicy,
    [string]$PolicyReason,
    [int]$StepIndex,
    [string]$Command,
    [string[]]$Arguments=@(),
    [string]$RequestsPath,
    [switch]$RequestsStdin,
    [string]$Route,
    [string]$ObservedResult,
    [string]$VerificationCommandId,
    [string[]]$VerificationCommandIds=@(),
    [ValidateSet('Compact','Full')] [string]$OutputMode='Compact'
)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Import-Module (Join-Path $PSScriptRoot 'Framework\AutomatedGuiTestingAgentFramework.psm1')
function Read-Requests {
    if ($RequestsStdin -and $RequestsPath) { throw 'Use RequestsStdin or RequestsPath, not both.' }
    if (-not $RequestsStdin -and -not $RequestsPath) { throw 'Provide RequestsPath for a JSON file, or RequestsStdin for UTF-8 JSON input.' }
    $raw=if ($RequestsStdin) { [Console]::In.ReadToEnd() } else { Get-Content -LiteralPath $RequestsPath -Raw }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Request JSON is empty; no action was dispatched.' }
    $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
}
function Write-Response($Result) {
    if ($OutputMode -eq 'Compact' -and $Result.explorationCommandId) {
        # Complete command results remain in the transcript; never truncate readback.
        $Result=[ordered]@{ok=$Result.ok;command=$Result.command;data=$Result.data;error=$Result.error;
            outcome=$Result.outcome;durationMs=$Result.durationMs;explorationCommandId=$Result.explorationCommandId;verification=$Result.verification}
    }
    $Result | ConvertTo-Json -Depth 80 -Compress
}
try {
    $RunRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
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
            $result=@{ok=$true;runRoot=$RunRoot;explorationPath=$paths.manifest;steps=@(Import-Csv -LiteralPath $TestCaseCsv);
                next='Set $OutputEncoding to UTF8Encoding(false), then pipe a JSON request array to powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-Exploration.ps1 -Action Batch -RunRoot <this-root> -RequestsStdin. This combines request creation and execution in one tool call. RequestsPath JSON files also work. Use RecordSteps for reviewed receipts, then close the owned app and Complete.'}
        }
        { $_ -in @('Command','Batch') } {
            if ($m.completed) { throw 'Exploration is complete; no action was dispatched.' }
            $requests=@([pscustomobject]@{stepIndex=$StepIndex;command=$Command;arguments=$Arguments})
            if ($Action -eq 'Batch') {
                $decoded=Read-Requests
                $requests=@($decoded)
            }
            if ($requests.Count -lt 1 -or $requests.Count -gt 20) { throw 'A known sequential batch must contain 1..20 commands.' }
            foreach ($request in $requests) {
                if ($request.stepIndex -lt 1 -or $request.stepIndex -gt $m.stepCount -or -not $request.command -or @($request.arguments | Where-Object {$_ -isnot [string]}).Count) { throw 'Every command needs a valid stepIndex, command and string arguments; no action was dispatched.' }
            }
            foreach ($request in $requests) {
                $values=@($request.arguments)
                if ($OutputMode -eq 'Compact' -and $request.command -eq 'observe' -and -not @($values | Where-Object {$_ -match '^--?Format(?:=|$)'}).Count) { $values+=@('-Format','Compact') }
                $result=Invoke-AGTAPotatoJson -PotatoCliPath $PotatoCliPath -Command $request.command -Arguments $values -RunRoot $RunRoot -InteractionPolicy $InteractionPolicy
                $id=Add-AGTAExplorationCommand $RunRoot $request.stepIndex $request.command $values $result
                $result | Add-Member -NotePropertyName explorationCommandId -NotePropertyValue $id -Force
                $result | Add-Member -NotePropertyName verification -NotePropertyValue (Get-AGTAExplorationVerificationInfo @{command=$request.command;result=$result}) -Force
                Write-Response $result
                if (-not (Test-AGTAExplorationCommandSucceeded $result $request.command)) { exit 1 }
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
    @{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
