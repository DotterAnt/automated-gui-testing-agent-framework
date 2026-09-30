[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScriptPath,
    [string] $TestCaseCsv,
    [string] $PotatoCliPath,
    [string] $ExplorationPath,
    [string] $InteractionPolicy='GuiNavigation'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Framework\GeneratedScriptRuntime.ps1')
$result = Test-AGTAGeneratedScript -ScriptPath $ScriptPath -TestCaseCsv $TestCaseCsv -PotatoCliPath $PotatoCliPath -ExplorationPath $ExplorationPath -InteractionPolicy $InteractionPolicy
$result | ConvertTo-Json -Depth 6 -Compress
if (-not $result.ok) { exit 1 }
