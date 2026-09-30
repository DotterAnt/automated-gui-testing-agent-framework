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
$RunRoot = $Context.RunRoot
# Build GUI output paths from the absolute context, for example:
# $OutputPath = Join-Path $Context.ExecutionEvidenceRoot 'output.ext'
# Context.ExecutionEvidenceRoot already exists. Add -PathKind SaveFile/OpenFile
# to type -Text $OutputPath; extra subdirectories must exist before filename entry.
# One scriptblock per CSV row, in order. Keep actions/assertions specific to the
# testcase here; the runtime handles dependency skips, cleanup and final output.
$StepBodies = @(
    # {
    #     param([ref] $Commands, [ref] $Evidence)
    #     $started = Invoke-StepCommand -Commands $Commands -Command start -Arguments @('-ProcessName','app.exe','-Maximize')
    #     Assert-PotatoOk $started
    #     $ready = Invoke-StepCommand -Commands $Commands -Command wait-element -Arguments @('-Name','<observed control>','-TimeoutMs','10000')
    #     Assert-PotatoFound $ready -Message '<CSV expected result>'
    # }
    # Add each remaining row with its tested GUI route and expected-result assertion.
)
Invoke-AGTATestPlan -StepBodies $StepBodies
exit (Get-AGTATestExitCode)
