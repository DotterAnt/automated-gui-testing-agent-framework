[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $TestCaseCsv,

    [ValidateSet('OpenAI', 'Mock')]
    [string] $Provider = 'OpenAI',

    [string] $Model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-5.5' }),

    [string] $PotatoCliPath = '',

    [switch] $Execute,

    [int] $MaxIterations = 20,

    [string] $SystemPrompt = '',

    [string] $SystemPromptPath = '',

    [string] $UserPrompt = '',

    [string] $UserPromptPath = '',
    [ValidateSet('VisibleControls','GuiNavigation','AllowShortcuts')] [string] $InteractionPolicy = 'GuiNavigation',
    [string] $PolicyReason
)

$ErrorActionPreference = 'Stop'

try {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Framework\AutomatedGuiTestingAgentFramework.psm1'
    Import-Module $modulePath -Force

    if (-not $PotatoCliPath) {
        $PotatoCliPath = Resolve-AGTADefaultPotatoCliPath
    }

    if ($SystemPromptPath) {
        if (-not (Test-Path -LiteralPath $SystemPromptPath)) { throw "System prompt file not found: $SystemPromptPath" }
        $SystemPrompt = Get-Content -LiteralPath $SystemPromptPath -Raw
    }
    if ($UserPromptPath) {
        if (-not (Test-Path -LiteralPath $UserPromptPath)) { throw "User prompt file not found: $UserPromptPath" }
        $UserPrompt = Get-Content -LiteralPath $UserPromptPath -Raw
    }

    $arguments = @{
        TestCaseCsv = $TestCaseCsv
        Provider = $Provider
        Model = $Model
        PotatoCliPath = $PotatoCliPath
        Execute = $Execute
        MaxIterations = $MaxIterations
        InteractionPolicy = $InteractionPolicy
        PolicyReason = $PolicyReason
    }
    if ($SystemPrompt) { $arguments.SystemPrompt = $SystemPrompt }
    if ($UserPrompt) { $arguments.UserPrompt = $UserPrompt }

    $result = Invoke-AGTAAgentAuthoring @arguments

    $result | ConvertTo-Json -Depth 80 -Compress
    if (-not $result.ok) { exit 1 }
}
catch {
    [pscustomobject][ordered]@{
        ok = $false
        provider = $Provider
        model = $Model
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 20 -Compress
    exit 1
}
