[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Begin','Command','Batch','RecordStep','Complete')] [string]$Action,
    [Parameter(Mandatory)] [string]$RunRoot,
    [Parameter(Mandatory)] [string]$TestCaseCsv,
    [string]$PotatoCliPath,
    [ValidateSet('GuiNavigation','VisibleControls','AllowShortcuts')] [string]$InteractionPolicy='GuiNavigation',
    [string]$PolicyReason,
    [int]$StepIndex,
    [string]$Command,
    [string[]]$Arguments=@(),
    [string]$RequestsPath,
    [string]$Route,
    [string]$ObservedResult,
    [string]$VerificationCommandId
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Framework\AutomatedGuiTestingAgentFramework.psm1')
if (-not $PotatoCliPath) { $PotatoCliPath=Resolve-AGTADefaultPotatoCliPath }
try {
    if ($InteractionPolicy -eq 'AllowShortcuts' -and -not $PolicyReason) { throw 'AllowShortcuts requires the explicit user/testcase authorization in PolicyReason.' }
    switch ($Action) {
        Begin { $result=Initialize-AGTAExploration $RunRoot $TestCaseCsv $InteractionPolicy }
        { $_ -in @('Command','Batch') } {
            # Validate the receipt destination BEFORE dispatching any GUI action.
            $paths=Get-AGTAExplorationPaths $RunRoot
            $m=Get-Content -LiteralPath $paths.manifest -Raw | ConvertFrom-Json
            if ($m.completed -or $m.interactionPolicy -ne $InteractionPolicy -or $m.testCaseHash -ne (Get-FileHash $TestCaseCsv).Hash) { throw 'Invalid exploration stage, CSV, or policy; no action was dispatched.' }
            $requests=@([pscustomobject]@{stepIndex=$StepIndex;command=$Command;arguments=$Arguments})
            if ($Action -eq 'Batch') { $decoded=Get-Content -LiteralPath $RequestsPath -Raw | ConvertFrom-Json; $requests=@($decoded) }
            if ($requests.Count -lt 1 -or $requests.Count -gt 20) { throw 'A known sequential batch must contain 1..20 commands.' }
            foreach ($request in $requests) {
                if ($request.stepIndex -lt 1 -or $request.stepIndex -gt $m.stepCount -or -not $request.command) { throw 'Every command needs a valid stepIndex and command; no action was dispatched.' }
            }
            foreach ($request in $requests) {
                $result=Invoke-AGTAPotatoJson -PotatoCliPath $PotatoCliPath -Command $request.command -Arguments @($request.arguments) -RunRoot $RunRoot -InteractionPolicy $InteractionPolicy
                $id=Add-AGTAExplorationCommand $RunRoot $request.stepIndex $request.command @($request.arguments) $result
                $result | Add-Member -NotePropertyName explorationCommandId -NotePropertyValue $id -Force
                $stop=-not $result.ok -or ($request.command -eq 'wait-element' -and -not $result.data.exists) -or ($request.command -eq 'wait-file' -and -not $result.data.conditionMet)
                if ($Action -eq 'Batch') {
                    $result | ConvertTo-Json -Depth 80 -Compress
                    if ($stop) { exit 1 }
                }
            }
            if ($Action -eq 'Batch') { return }
        }
        RecordStep { $result=Complete-AGTAExplorationStep $RunRoot $StepIndex $Route $ObservedResult $VerificationCommandId }
        Complete { $result=Complete-AGTAExploration $RunRoot $TestCaseCsv $InteractionPolicy }
    }
    $result | ConvertTo-Json -Depth 80 -Compress
    if ($result.ok -eq $false) { exit 1 }
} catch {
    @{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
