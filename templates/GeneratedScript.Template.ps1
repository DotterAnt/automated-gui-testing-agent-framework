[CmdletBinding()]
param(
    [string] $PotatoCliPath,
    [string] $TestCaseCsv,
    [string] $RunRoot,
    [string] $FrameworkRoot,
    [string] $ExplorationPath,
    [ValidateSet('VisibleControls','GuiNavigation','AllowShortcuts')] [string] $InteractionPolicy = 'GuiNavigation',
    [string] $PolicyReason,
    [ValidateSet('InProcess','Process')] [string] $Transport = 'InProcess'
)

$runtimeCandidates = @()
if ($FrameworkRoot) {
    $runtimeCandidates += (Join-Path -Path $FrameworkRoot -ChildPath 'Framework\GeneratedScriptRuntime.ps1')
}
$probe = $PSScriptRoot
for ($i = 0; $i -lt 6 -and $probe; $i++) {
    $runtimeCandidates += (Join-Path -Path $probe -ChildPath 'Framework\GeneratedScriptRuntime.ps1')
    $probe = Split-Path -Parent $probe
}
$runtimePath = @($runtimeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
if (-not $runtimePath) {
    throw "Generated script runtime was not found: $runtimePath"
}
$FrameworkRoot = Split-Path -Parent (Split-Path -Parent $runtimePath)
. $runtimePath

# Resolve generated helper calls and inputs before any desktop action.
if (-not $ExplorationPath) { $ExplorationPath = Join-Path $RunRoot 'logs\exploration.json' }
Assert-AGTAGeneratedScriptPreflight -ScriptPath $PSCommandPath -TestCaseCsv $TestCaseCsv -PotatoCliPath $PotatoCliPath -ExplorationPath $ExplorationPath -InteractionPolicy $InteractionPolicy | Out-Null

$Context = Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot -RequireAssertions -InteractionPolicy $InteractionPolicy -PolicyReason $PolicyReason -Transport $Transport -ExplorationPath $ExplorationPath
$results = @()
$cleanup = @()

try {
    for ($i = 0; $i -lt $Context.Steps.Count; $i++) {
        $results += New-StepResult `
            -StepIndex ($i + 1) `
            -Action $Context.Steps[$i].Action `
            -ExpectedResult $Context.Steps[$i].'Expected Result' `
            -Status 'SKIPPED' `
            -ErrorObject 'Template placeholder: implement this step with Invoke-RecordedStep.'
    }

    # Example shape for real step implementations:
    #
    # $results += Invoke-RecordedStep -StepIndex 1 -Body {
    #     param([ref] $Commands, [ref] $Evidence)
    #     $started = Invoke-StepCommand -Commands $Commands -Command 'start' -Arguments @('-ProcessName', 'notepad.exe', '-WaitForWindowMs', '10000')
    #     Assert-PotatoOk -Result $started -Message 'Could not start the target app.'
    #     Assert-ExpectedResult -Condition ([bool]$started.data.windowFound) -Message 'The target application window must be visible.'
    #     # Invoke-StepCommand auto-registers a newly owned process for scoped cleanup.
    #     Invoke-EvidenceScreenshot -Commands $Commands -Evidence $Evidence -FileName '01-opened.png' | Out-Null
    # }
}
finally {
    $cleanup = @(Invoke-TestCleanup)
}

Complete-AGTAGeneratedTest -StepResults $results -Cleanup $cleanup

exit (Get-AGTATestExitCode)
