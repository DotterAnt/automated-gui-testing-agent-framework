. (Join-Path $PSScriptRoot 'Exploration.ps1')

function Get-AGTARuntimeHelp {
    [CmdletBinding()]
    param([string] $Name)
    $published = @(
        'Initialize-AGTAGeneratedTest', 'Invoke-RecordedStep', 'Invoke-StepCommand', 'Invoke-StepClick', 'Invoke-AGTATestPlan',
        'Assert-PotatoOk', 'Assert-PotatoFound', 'Assert-FileWait',
        'Assert-ExpectedResult', 'Assert-TextContains', 'Read-AGTAArtifactBytes', 'Read-AGTAZipText', 'Assert-ZipTextContains', 'Assert-ArtifactPrefix', 'Assert-ImageContainsColors',
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
        $constraints=[ordered]@{}
        foreach ($parameter in $command.Parameters.Values) {
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute -is [Management.Automation.ValidateRangeAttribute]) { $constraints[$parameter.Name]=@{minimum=$attribute.MinRange;maximum=$attribute.MaxRange} }
                elseif ($attribute -is [Management.Automation.ValidateSetAttribute]) {$constraints[$parameter.Name]=@{values=@($attribute.ValidValues)}}
            }
        }
        [pscustomobject]@{
            name = $command.Name
            syntax = [string](Get-Command -Syntax -Name $helper)
            sourcePath = $command.ScriptBlock.File
            available = $true
            parameterConstraints = $constraints
            note = switch ($helper) {
                Read-AGTAArtifactBytes {'Count is an exact byte count, not a maximum or whole-file read. Use Read-AGTAZipText for archive text.'}
                Read-AGTAZipText {'Returns an array of {name,text} entries, not a CLI result. MaxBytes limits total uncompressed content. Use Assert-ZipTextContains for raw archive text, or assert entry.text explicitly; do not pass entries to Assert-TextContains.'}
                Assert-ZipTextContains {'Reads actual matching ZIP entries and asserts raw text fragments with ordinal comparison and normalized CR/LF. Optional ExpectedEntryCount asserts cardinality. XML entities are not decoded; use a read-only parser for semantic XML assertions.'}
                Assert-TextContains {'Result must be a successful CLI read/read-pdf envelope with content provenance. For archive entries use Assert-ZipTextContains; plain strings and {name,text} objects are not CLI results.'}
                Assert-ImageContainsColors {'Read-only shared decode and compiled pixel scan, bounded by MaxBytes/MaxPixels. ColorRanges objects: name,rMin,rMax,gMin,gMax,bMin,bMax,aMin (RGB defaults 0..255, aMin defaults 1). Each needs MinimumPixels. ExpectedFormat checks actual signature/decoded format, not extension. PassThru returns counts/dimensions. Color presence alone does not prove shape, layout, record count or correct GUI creation.'}
                Invoke-StepCommand {'*Json option values may be strings or objects; objects are serialized before CLI invocation.'}
                default {$null}
            }
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
    foreach ($assignment in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst]}, $true))) {
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $assignment.Left.VariablePath.UserPath -match '^(?:(?:global|script|local):)?(?:HOME|PID|PSVersionTable|PSEdition|PSHOME|Host|ExecutionContext|ShellId|true|false)$') {
            $issues += "Line $($assignment.Extent.StartLineNumber): '$($assignment.Left.Extent.Text)' is an automatic read-only/constant variable. Use a testcase-specific variable name before running the GUI."
        }
    }
    foreach ($definition in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))) {
        $localFunctions[$definition.Name] = $true
    }
    $checked = 0
    foreach ($call in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true))) {
        $name = $call.GetCommandName()
        if ($name -eq 'Read-AGTAArtifactBytes' -and -not $localFunctions.ContainsKey($name)) {
            $parts=@($call.CommandElements)
            for ($i=1;$i -lt $parts.Count;$i++) {
                if ($parts[$i] -is [Management.Automation.Language.CommandParameterAst] -and $parts[$i].ParameterName -eq 'Count') {
                    $value=$parts[$i].Argument
                    if (-not $value -and $i+1 -lt $parts.Count) { $value=$parts[$i+1] }
                    $countValue=0L
                    if ($value -is [Management.Automation.Language.ConstantExpressionAst] -and
                        (-not [long]::TryParse([string]$value.Value,[ref]$countValue) -or $countValue -lt 1 -or $countValue -gt 1048576)) {
                        $issues += "Line $($parts[$i].Extent.StartLineNumber): Read-AGTAArtifactBytes -Count must be 1..1048576 and reads exactly that many bytes. For ZIP text/content use Read-AGTAZipText; do not guess the archive size."
                    }
                }
            }
        }
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
        if ($name -in @('Invoke-CimMethod','Invoke-WmiMethod','Set-CimInstance','New-CimInstance','Remove-CimInstance','Set-WmiInstance','Remove-WmiObject','Set-Printer','Add-Printer','Remove-Printer','Rename-Printer')) {
            $issues += "Line $($call.Extent.StartLineNumber): '$name' changes system/application state outside the recorded GUI route. Use visible controls; read-only management queries remain available for verification."
        }
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
        if (($memberCall.Static -and $memberCall.Member.Extent.Text -eq 'FromImage' -and $memberCall.Expression.Extent.Text -match '^\[(?:System\.)?Drawing\.Graphics\]$') -or
            $memberCall.Member.Extent.Text -match '^(?i:DrawLine|DrawLines|DrawRectangle|DrawEllipse|DrawString|FillRectangle|FillEllipse|FillPolygon)$') {
            $issues += "Line $($memberCall.Extent.StartLineNumber): drawing image contents in code substitutes generated data for the tested GUI action. Create required contents through the GUI; existing input fixtures and read-only image inspection are separate from expected outputs."
        }
        if ($memberCall.Member.Extent.Text -match '^(?i:SendWait|SendText|SendInput|mouse_event|SetCursorPos|GetActiveObject|GetTypeFromProgID|CreateInstance|ExecuteNonQuery|SetValue)$') {
            $issues += "Line $($memberCall.Extent.StartLineNumber): direct '$($memberCall.Member.Extent.Text)' can bypass GUI input or create expected data. Use the CLI for actions and read-only artifact checks for verification."
        }
        if ($memberCall.Member.Extent.Text -eq 'SetDefaultPrinter') {
            $issues += "Line $($memberCall.Extent.StartLineNumber): change printer selection through its visible GUI, not a direct system configuration method."
        }
        if ($memberCall.Static -and $memberCall.Member.Extent.Text -eq 'ReadAllBytes' -and
            $memberCall.Expression.Extent.Text -match '^\[(?:System\.)?IO\.File\]$') {
            $issues += "Line $($memberCall.Extent.StartLineNumber): direct File.ReadAllBytes can fail on an output still held by its application. Use Read-AGTAArtifactBytes or Assert-ArtifactPrefix for bounded shared reads."
        }
    }
    # Literal embedded scripts were the observed OLE DB/PDF-fabrication escape.
    # Inspect code strings as well as PowerShell calls, without executing them.
    foreach ($literal in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst]}, $true))) {
        if ($literal.Value -match '(?i)\bFileProtocolHandler\b|\bShellExec_RunDLL\b|/[ck]\s+start\b|(?:javascript|vbscript):.*(?:\.Run|ShellExecute)|\bStart-Process\s+.*://') {
            $issues += "Line $($literal.Extent.StartLineNumber): shell/protocol launcher bypasses the GUI file-opening route. Use a new file-manager window, its visible Open action, and focus the resulting viewer."
        }
        if ($literal.Value -match '(?i)\bExecuteNonQuery\s*\(|\b(?:SendInput|SendWait|GetActiveObject|GetTypeFromProgID)\s*\(|New-Object\s+-ComObject\b|System\.Drawing\.Printing\.PrintDocument|\b(?:reportlab|fpdf)\b|%PDF-\d') {
            $issues += "Line $($literal.Extent.StartLineNumber): embedded mutation/input/artifact-generation code requires removal; expected outputs must be produced through the tested GUI."
        }
        if ($literal.Value -match '(?i)\bImageDraw\.(?:Draw|line|rectangle|ellipse)\s*\(|\bGraphics\]::FromImage\s*\(|\.DrawLine\s*\(') {
            $issues += "Line $($literal.Extent.StartLineNumber): embedded image drawing fabricates testcase content outside the GUI. Use recorded mouse actions; render/inspect actual outputs read-only for verification."
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
