. (Join-Path $PSScriptRoot 'Exploration.ps1')

function Get-AGTARuntimeHelp {
    [CmdletBinding()]
    param([string] $Name)
    $published = @(
        'Initialize-AGTAGeneratedTest', 'Invoke-RecordedStep', 'Invoke-StepCommand', 'Invoke-StepClick', 'Invoke-AGTATestPlan',
        'Assert-PotatoOk', 'Assert-PotatoFound', 'Assert-FileWait',
        'Assert-ExpectedResult', 'Assert-TextContains', 'Read-AGTAArtifactBytes', 'Assert-ArtifactPrefix',
        'Invoke-EvidenceScreenshot', 'Add-EvidencePath', 'Register-OpenedProcess',
        'Register-CreatedExternalPath', 'Invoke-TestCleanup',
        'Complete-AGTAGeneratedTest', 'Get-AGTATestExitCode',
        'Test-AGTAGeneratedScript', 'Assert-AGTAGeneratedScriptPreflight'
    )
    if ($Name -and $Name -notin $published) {
        throw "Unknown generated-runtime helper '$Name'. Call Get-AGTARuntimeHelp without -Name to list helpers."
    }
    $names = if ($Name) { @($Name) } else { $published }
    foreach ($helper in $names) {
        $command = Get-Command -Name $helper -CommandType Function -ErrorAction Stop
        [pscustomobject]@{
            name = $command.Name
            syntax = [string](Get-Command -Syntax -Name $helper)
            sourcePath = $command.ScriptBlock.File
            available = $true
        }
    }
}

function Test-AGTAGeneratedScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ScriptPath,
          [string] $TestCaseCsv,
          [string] $PotatoCliPath,
          [string] $ExplorationPath,
          [string] $InteractionPolicy = 'GuiNavigation',
          [switch] $PolicyOnly)
    $issues = @()
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ok=$false;issues=@("Script not found: $ScriptPath");checkedCommands=0}
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($error in @($parseErrors)) { $issues += "Line $($error.Extent.StartLineNumber): $($error.Message)" }
    if ($PotatoCliPath -and -not (Test-Path -LiteralPath $PotatoCliPath -PathType Leaf)) { $issues += "CLI entry point not found: $PotatoCliPath" }
    if ($TestCaseCsv) {
        if (-not (Test-Path -LiteralPath $TestCaseCsv -PathType Leaf)) { $issues += "Testcase CSV not found: $TestCaseCsv" }
        else {
            try {
                $rows = @(Import-Csv -LiteralPath $TestCaseCsv)
                if (-not $rows.Count) { $issues += 'Testcase CSV is empty.' }
                else {
                    foreach ($column in @('Action','Data','Expected Result')) {
                        if ($column -notin $rows[0].PSObject.Properties.Name) { $issues += "Testcase CSV missing column: $column" }
                    }
                }
            }
            catch { $issues += "Testcase CSV cannot be read: $($_.Exception.Message)" }
        }
    }
    if ($TestCaseCsv -and (Split-Path -Leaf $ScriptPath) -ne 'GeneratedScript.Template.ps1') {
        $exploration=Test-AGTAExploration -Path $ExplorationPath -TestCaseCsv $TestCaseCsv -InteractionPolicy $InteractionPolicy
        $issues += @($exploration.issues)
    }
    $localFunctions = @{}
    foreach ($definition in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))) {
        $localFunctions[$definition.Name] = $true
    }
    $checked = 0
    foreach ($call in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true))) {
        $name = $call.GetCommandName()
        if ($name -match '^(?:New-Object)$' -and $call.Extent.Text -match '(?i)-ComObject\b') {
            $issues += "Line $($call.Extent.StartLineNumber): application COM automation bypasses the required GUI route. Use recorded CLI actions."
        }
        if ($name -eq 'New-Object' -and $call.Extent.Text -match '(?i)System\.Drawing\.Printing\.PrintDocument') {
            $issues += "Line $($call.Extent.StartLineNumber): printing a synthetic document bypasses the target application's print route. Print the actual document through its GUI."
        }
        if ($name -in @('Set-Clipboard','Get-Clipboard','Invoke-Expression','iex')) {
            $issues += "Line $($call.Extent.StartLineNumber): '$name' bypasses the recorded GUI workflow."
        }
        if ($name -eq 'Add-Type' -and $call.Extent.Text -match '(?i)-(TypeDefinition|MemberDefinition|Path)\b') {
            $issues += "Line $($call.Extent.StartLineNumber): generated scripts must not compile/load private input backends. Use type, press-key, or relative click through the CLI."
        }
        if ($name -eq 'Start-Process') { $issues += "Line $($call.Extent.StartLineNumber): use recorded CLI start for executable launches and the GUI Open route for documents; direct Start-Process bypasses ownership and route checks." }
        if ($PolicyOnly) { continue }
        if (-not $name -or $localFunctions.ContainsKey($name)) { continue }
        $checked++
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            $issues += "Line $($call.Extent.StartLineNumber): command '$name' is unavailable. Dot-source its helper file or correct the name."
            continue
        }
        if ($command.CommandType -notin @('Function','Cmdlet','Alias')) { continue }
        foreach ($parameter in @($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
            if (-not $command.Parameters.ContainsKey($parameter.ParameterName)) {
                $issues += "Line $($parameter.Extent.StartLineNumber): '$name' has no parameter '-$($parameter.ParameterName)'."
            }
        }
    }
    foreach ($memberCall in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst]}, $true))) {
        if ($memberCall.Member.Extent.Text -match '^(?i:SendWait|SendText|SendInput|mouse_event|SetCursorPos|GetActiveObject|GetTypeFromProgID|CreateInstance|ExecuteNonQuery|SetValue)$') {
            $issues += "Line $($memberCall.Extent.StartLineNumber): direct '$($memberCall.Member.Extent.Text)' can bypass GUI input or create expected data. Use the CLI for actions and read-only artifact checks for verification."
        }
        if ($memberCall.Static -and $memberCall.Member.Extent.Text -eq 'ReadAllBytes' -and
            $memberCall.Expression.Extent.Text -match '^\[(?:System\.)?IO\.File\]$') {
            $issues += "Line $($memberCall.Extent.StartLineNumber): direct File.ReadAllBytes can fail on an output still held by its application. Use Read-AGTAArtifactBytes or Assert-ArtifactPrefix for bounded shared reads."
        }
    }
    # Literal embedded scripts were the observed OLE DB/PDF-fabrication escape.
    # Inspect code strings as well as PowerShell calls, without executing them.
    foreach ($literal in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst]}, $true))) {
        if ($literal.Value -match '(?i)\bExecuteNonQuery\s*\(|\b(?:SendInput|SendWait|GetActiveObject|GetTypeFromProgID)\s*\(|New-Object\s+-ComObject\b|System\.Drawing\.Printing\.PrintDocument|\b(?:reportlab|fpdf)\b|%PDF-\d') {
            $issues += "Line $($literal.Extent.StartLineNumber): embedded mutation/input/artifact-generation code requires removal; expected outputs must be produced through the tested GUI."
        }
    }
    return [pscustomobject]@{ok=($issues.Count -eq 0);issues=@($issues | Select-Object -Unique);checkedCommands=$checked;policyAssessment='Static checks and recorded CLI actions; not an execution sandbox.'}
}

function Assert-AGTAGeneratedScriptPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ScriptPath,
          [string] $TestCaseCsv,
          [string] $PotatoCliPath,
          [string] $ExplorationPath,
          [string] $InteractionPolicy = 'GuiNavigation')
    $result = Test-AGTAGeneratedScript -ScriptPath $ScriptPath -TestCaseCsv $TestCaseCsv -PotatoCliPath $PotatoCliPath -ExplorationPath $ExplorationPath -InteractionPolicy $InteractionPolicy
    if (-not $result.ok) { throw ('Generated script preflight failed: ' + ($result.issues -join '; ')) }
    return $result
}
