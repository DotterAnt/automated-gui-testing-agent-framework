. (Join-Path $PSScriptRoot 'Exploration.ps1')

function Get-AGTARuntimeHelp {
    [CmdletBinding()]
    param([string] $Name)
    $published = @(
        'Initialize-AGTAGeneratedTest', 'Invoke-RecordedStep', 'Invoke-StepCommand', 'Invoke-StepClick', 'Invoke-AGTATestPlan',
        'Assert-PotatoOk', 'Assert-PotatoFound', 'Assert-FileWait',
        'Assert-ExpectedResult', 'Assert-TextContains', 'Read-AGTAArtifactBytes', 'Read-AGTAZipText', 'Assert-ZipTextContains', 'Assert-ArtifactPrefix', 'Assert-ImageContainsColors', 'Assert-ImageRegionMatches', 'Measure-ImageRegionMatch',
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
                Measure-ImageRegionMatch {'Read-only diagnostic metrics for an existing actual image/Region against a complete ReferencePath, optionally rotated clockwise. Returns meanError,maxTileError,aspectError,region,referenceWidth/Height and decoded-pixel provenance. No tolerance, assertion, PASS or GUI action. Use this to diagnose region/orientation on retained screenshots without another replay or relaxed assertion thresholds; keep Assert-ImageRegionMatches in replay.'}
                Assert-ImageRegionMatches {'Compare actual decoded pixels against the complete existing reference, optionally rotated clockwise by 0/90/180/270. Region is an observed {x,y,width,height} rectangle in Path pixels; omit for the whole output image. Checks aspect ratio and RGB errors on a 128x128 grid plus each of 64 tiles, allowing tested JPEG/render differences. Defaults: mean <=8, worst tile <=24, aspect error <=2%; hard limits: mean 32, tile 64. Fix capture region/orientation/readiness instead of increasing tolerances after failures. For live opaque content, screenshot WaitForImageMatch/MatchRegionJson awaits expected pixels; change/stability alone may be a loading frame. This is an approximate content comparison, not byte equality or a PDF renderer. Render an actual PDF first with an available read-only renderer, then compare its observed image region. Never use marker regex/header/dimensions as a replacement. PassThru returns measured errors/provenance.'}
                Invoke-StepCommand {'*Json option values may be strings or objects; objects are serialized before CLI invocation.'}
                Add-EvidencePath {'Pass the current row reference: -Evidence $Evidence -Path <saved evidence>. Merely saving/adding a screenshot does not assert its contents.'}
                Assert-ExpectedResult {'Condition must be a Boolean measured from actual state/content. Literal $true is rejected by preflight. Dispatch, filenames, image dimensions or a PDF header alone do not prove all content expectations.'}
                Assert-PotatoFound {'Asserts existence/count/exists, not absence. For windows -WaitForNotExists assert data.conditionMet using Assert-ExpectedResult.'}
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
    # Derive the context contract from its initializer, without invoking it or
    # supplied code. Catch typos in late rendering/assertion helpers before a
    # full GUI replay. Only apply this to scripts using the framework context.
    $contextAssignment=$ast.Find({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'Context' -and
        $node.Right.Find({param($call) $call -is [Management.Automation.Language.CommandAst] -and
            $call.GetCommandName() -in @('Initialize-AGTAGeneratedTest','Get-AGTAGeneratedTestContext')},$true)
    },$true)
    if ($contextAssignment) {
        $initializer=(Get-Command Initialize-AGTAGeneratedTest -CommandType Function).ScriptBlock.Ast
        $schemaAssignment=$initializer.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$script:AGTAGeneratedTestContext'},$true)
        $schema=$schemaAssignment.Right.Find({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true)
        $contextProperties=@($schema.KeyValuePairs | ForEach-Object {$_.Item1.Value})+@('PSObject')
        # Explicit custom properties are allowed; this is typo detection, not
        # a prohibition on extending the context.
        $members=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.MemberExpressionAst] -and
            $node -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -eq 'Context' -and
            $node.Member -is [Management.Automation.Language.StringConstantExpressionAst]},$true))
        $declared=@($members | Where-Object {$_.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Parent.Left -eq $_} | ForEach-Object {$_.Member.Value})
        foreach ($member in $members) {
            if ($member.Member.Value -notin $contextProperties -and $member.Member.Value -notin $declared) {
                $issues+="Line $($member.Extent.StartLineNumber): unknown framework Context property '$($member.Member.Value)'. Use ExecutionEvidenceRoot for this replay's screenshots/rendered artifacts. Context properties: $($contextProperties -join ', ')."
            }
        }
    }
    foreach ($parameter in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.ParameterAst]}, $true))) {
        $default=$parameter.DefaultValue
        if ($default -isnot [Management.Automation.Language.StringConstantExpressionAst] -and $default -isnot [Management.Automation.Language.ExpandableStringExpressionAst]) {continue}
        if ($parameter.Name.VariablePath.UserPath -eq 'InteractionPolicy' -and $default.Value -eq 'AllowShortcuts') {
            $issues+="Line $($parameter.Extent.StartLineNumber): generated scripts must default to GuiNavigation or an explicitly requested VisibleControls policy. AllowShortcuts must be supplied by an authorized caller, never enabled by a script default."
        }
        if ($parameter.Name.VariablePath.UserPath -eq 'PolicyReason' -and -not [string]::IsNullOrWhiteSpace($default.Value)) {
            $issues+="Line $($parameter.Extent.StartLineNumber): a generated PolicyReason default cannot supply user authorization. Leave it empty and accept an existing authorization from the caller."
        }
    }
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
    $commandMetadata = @{}
    $screenshotPaths=@{}
    foreach ($assignment in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst]}, $true))) {
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $assignment.Right.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-EvidenceScreenshot'},$true)) {
            $screenshotPaths[$assignment.Left.VariablePath.UserPath]=$true
        }
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $assignment.Left.VariablePath.UserPath -match '^(?:(?:global|script|local):)?InteractionPolicy$' -and
            $assignment.Right.Extent.Text -match '^\s*([''"])AllowShortcuts\1\s*$') {
            $issues+="Line $($assignment.Extent.StartLineNumber): generated code cannot grant itself AllowShortcuts. Preserve the policy supplied by the caller."
        }
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $assignment.Left.VariablePath.UserPath -match '^(?:(?:global|script|local):)?(?:HOME|PID|PSVersionTable|PSEdition|PSHOME|Host|ExecutionContext|ShellId|true|false)$') {
            $issues += "Line $($assignment.Extent.StartLineNumber): '$($assignment.Left.Extent.Text)' is an automatic read-only/constant variable. Use a testcase-specific variable name before running the GUI."
        }
    }
    foreach ($definition in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))) {
        $localFunctions[$definition.Name] = $true
    }
    foreach ($shotCall in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-StepCommand'},$true))) {
        foreach ($argumentArray in @($shotCall.FindAll({param($node) $node -is [Management.Automation.Language.ArrayLiteralAst]},$true))) {
            $argumentParts=@($argumentArray.Elements);$literalOptions=@{};$guarded=$false
            for ($i=0;$i -lt $argumentParts.Count;$i++) {
                if ($argumentParts[$i] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {continue}
                $option=[string]$argumentParts[$i].Value
                if ($option -match '^-(?<name>[^=]+)(?:=(?<value>.*))?$') {
                    $optionName=$Matches.name;$literalOptions[$optionName]=$true
                    if ($optionName -eq 'Scope' -and $Matches.value -eq 'ForegroundWindow') {$guarded=$true}
                }
                if ($option -eq '-Scope' -and $i+1 -lt $argumentParts.Count -and
                    $argumentParts[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst] -and $argumentParts[$i+1].Value -eq 'ForegroundWindow') {$guarded=$true}
            }
            if ($guarded) {
                foreach ($required in @('WindowSelectorJson','FallbackReason','FallbackEvidence')) {
                    if (-not $literalOptions.ContainsKey($required)) {$issues+="Line $($argumentArray.Extent.StartLineNumber): guarded ForegroundWindow requires -$required. Preserve the tested window identity and fallback evidence before replay."}
                }
            }
        }
        $shotParts=@($shotCall.CommandElements);$isScreenshot=$false
        for ($i=1;$i -lt $shotParts.Count;$i++) {
            if ($shotParts[$i] -isnot [Management.Automation.Language.CommandParameterAst] -or $shotParts[$i].ParameterName -ne 'Command') {continue}
            $value=$shotParts[$i].Argument
            if (-not $value -and $i+1 -lt $shotParts.Count) {$value=$shotParts[$i+1]}
            $isScreenshot=$value -is [Management.Automation.Language.StringConstantExpressionAst] -and $value.Value -eq 'screenshot'
        }
        if (-not $isScreenshot) {continue}
        foreach ($array in @($shotCall.FindAll({param($node) $node -is [Management.Automation.Language.ArrayLiteralAst]},$true))) {
            for ($i=0;$i -lt $array.Elements.Count-1;$i++) {
                if ($array.Elements[$i] -is [Management.Automation.Language.StringConstantExpressionAst] -and $array.Elements[$i].Value -eq '-OutFile' -and
                    $array.Elements[$i+1] -is [Management.Automation.Language.VariableExpressionAst]) {$screenshotPaths[$array.Elements[$i+1].VariablePath.UserPath]=$true}
            }
        }
    }
    # Follow simple screenshot/path metadata aliases without evaluating code.
    # A compound expression is not automatically a content assertion: both
    # Test-Path and a nonzero Length can still describe an empty/useless capture.
    $screenshotMetadata=@{}
    foreach ($key in $screenshotPaths.Keys) {$screenshotMetadata[$key]=$true}
    $assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst]},$true))
    for ($pass=0;$pass -lt $assignments.Count;$pass++) {
        $added=$false
        foreach ($assignment in $assignments) {
            if ($assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst]) {continue}
            $key=$assignment.Left.VariablePath.UserPath
            if ($screenshotMetadata.ContainsKey($key)) {continue}
            $variables=@($assignment.Right.FindAll({param($node) $node -is [Management.Automation.Language.VariableExpressionAst]},$true))
            if (-not @($variables | Where-Object {$screenshotMetadata.ContainsKey($_.VariablePath.UserPath)}).Count) {continue}
            if (Test-AGTAScreenshotMetadataExpression $assignment.Right $screenshotMetadata) {$screenshotMetadata[$key]=$true;$added=$true}
        }
        if (-not $added) {break}
    }
    $hasStepBodies=@($assignments | Where-Object {$_.Left -is [Management.Automation.Language.VariableExpressionAst] -and $_.Left.VariablePath.UserPath -match '^(?:(?:script|local):)?StepBodies$'}).Count -gt 0
    $checked = 0
    foreach ($call in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true))) {
        $name = $call.GetCommandName()
        $parts=@($call.CommandElements)
        if ($name -eq 'Assert-ExpectedResult' -and -not $localFunctions.ContainsKey($name)) {
            for ($i=1;$i -lt $parts.Count;$i++) {
                if ($parts[$i] -isnot [Management.Automation.Language.CommandParameterAst] -or $parts[$i].ParameterName -ne 'Condition') {continue}
                $condition=$parts[$i].Argument
                if (-not $condition -and $i+1 -lt $parts.Count) {$condition=$parts[$i+1]}
                if ($condition -and $condition.Extent.Text -match '^\s*\(*\s*\$true\s*\)*\s*$') {
                    $issues+="Line $($condition.Extent.StartLineNumber): Assert-ExpectedResult -Condition `$true always passes and cannot verify a GUI result. Assert actual readback/content or a measured postcondition; a saved screenshot alone is evidence, not an automated assertion."
                }
                if ($condition -and $condition.Find({param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -and $screenshotMetadata.ContainsKey($node.VariablePath.UserPath)},$true) -and
                    (Test-AGTAScreenshotMetadataExpression $condition $screenshotMetadata)) {
                    $issues+="Line $($condition.Extent.StartLineNumber): screenshot existence/file metadata cannot verify its contents or count as an expected-result assertion. Add the screenshot as evidence and compare its observed image region with Assert-ImageRegionMatches or assert actual content readback."
                }
            }
        }
        for ($i=1;$i -lt $parts.Count;$i++) {
            if ($parts[$i] -isnot [Management.Automation.Language.CommandParameterAst]) {continue}
            $value=$parts[$i].Argument
            if (-not $value -and $i+1 -lt $parts.Count) {$value=$parts[$i+1]}
            if ($value -isnot [Management.Automation.Language.StringConstantExpressionAst]) {continue}
            if ($parts[$i].ParameterName -eq 'InteractionPolicy' -and $value.Value -eq 'AllowShortcuts') {
                $issues+="Line $($parts[$i].Extent.StartLineNumber): generated calls cannot hardcode AllowShortcuts. Use the declared caller policy and its existing authorization."
            }
            if ($parts[$i].ParameterName -eq 'Command' -and $value.Value -eq 'hotkey' -and $InteractionPolicy -ne 'AllowShortcuts') {
                $issues+="Line $($parts[$i].Extent.StartLineNumber): hotkey is forbidden by $InteractionPolicy. Use observed visible controls; navigation keys remain available under GuiNavigation."
            }
        }
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
        $fileCommand=$name
        if ($fileCommand -in @('mv','move','mi','cp','copy','cpi','ren','rni','rm','del','erase','rd','ri','rmdir')) {
            $alias=Get-Command $fileCommand -CommandType Alias -ErrorAction SilentlyContinue
            if ($alias) {$fileCommand=$alias.ResolvedCommand.Name}
        }
        if ($fileCommand -in @('Move-Item','Copy-Item','Rename-Item') -or ($hasStepBodies -and $fileCommand -eq 'Remove-Item')) {
            $issues+="Line $($call.Extent.StartLineNumber): '$name' mutates files outside the recorded GUI route. Use the application's observed Save/rename/location controls and fresh execution output paths; never relocate a default save or pre-delete an existing user file to satisfy a CSV step. External cleanup belongs to the runtime ownership workflow."
        }
        if ($name -in @('Invoke-CimMethod','Invoke-WmiMethod','Set-CimInstance','New-CimInstance','Remove-CimInstance','Set-WmiInstance','Remove-WmiObject','Set-Printer','Add-Printer','Remove-Printer','Rename-Printer')) {
            $issues += "Line $($call.Extent.StartLineNumber): '$name' changes system/application state outside the recorded GUI route. Use visible controls; read-only management queries remain available for verification."
        }
        if (-not $name -or $localFunctions.ContainsKey($name)) { continue }
        if (-not $PolicyOnly) {$checked++}
        # Resolve each distinct command once per audit. Repeated calls need the
        # same metadata; repeated module discovery adds no validation coverage.
        if (-not $commandMetadata.ContainsKey($name)) {$commandMetadata[$name]=Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1}
        $command=$commandMetadata[$name]
        if (-not $command) {
            if (-not $PolicyOnly) {$issues += "Line $($call.Extent.StartLineNumber): command '$name' is unavailable. Dot-source its helper file or correct the name."}
            continue
        }
        if ($command.CommandType -notin @('Function','Cmdlet','Alias')) { continue }
        foreach ($parameter in @($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
            if (-not $command.Parameters.ContainsKey($parameter.ParameterName)) {
                if (-not $PolicyOnly) {$issues += "Line $($parameter.Extent.StartLineNumber): '$name' has no parameter '-$($parameter.ParameterName)'."}
                continue
            }
            $value=$parameter.Argument
            if (-not $value) {
                $position=[Array]::IndexOf($parts,$parameter)
                if ($position+1 -lt $parts.Count) {$value=$parts[$position+1]}
            }
            # Validate literal values without evaluating any supplied code or
            # launching GUI actions. Dynamic expressions still need runtime checks.
            if ($value -is [Management.Automation.Language.ConstantExpressionAst] -or $value -is [Management.Automation.Language.StringConstantExpressionAst]) {
                $metadata=$command.Parameters[$parameter.ParameterName]
                if ($metadata.ParameterType.IsEnum) {
                    try {
                        $enumValue=[Enum]::Parse($metadata.ParameterType,[string]$value.Value,$true)
                        if (-not [Enum]::IsDefined($metadata.ParameterType,$enumValue) -and -not $metadata.ParameterType.IsDefined([FlagsAttribute],$false)) {throw 'Undefined enum value'}
                    } catch {$issues+="Line $($value.Extent.StartLineNumber): '$name -$($parameter.ParameterName) $($value.Value)' is unsupported in PowerShell $($PSVersionTable.PSVersion). Use a supported value or shared artifact helpers before replaying the GUI."}
                }
                foreach ($attribute in $metadata.Attributes) {
                    if ($attribute -is [Management.Automation.ValidateSetAttribute] -and [string]$value.Value -notin $attribute.ValidValues) {
                        $issues+="Line $($value.Extent.StartLineNumber): '$name -$($parameter.ParameterName)' requires one of: $($attribute.ValidValues -join ', ')."
                    }
                    if ($attribute -is [Management.Automation.ValidateRangeAttribute] -and $attribute.MinRange -is [ValueType] -and $attribute.MaxRange -is [ValueType]) {
                        $number=0.0
                        $numeric=[double]::TryParse([string]$value.Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)
                        if (-not $numeric -or [double]::IsNaN($number) -or $number -lt [double]$attribute.MinRange -or $number -gt [double]$attribute.MaxRange) {
                            $detail=if ($name -eq 'Assert-ImageRegionMatches') {' Fix the observed region, orientation or readiness; never raise tolerances to turn a failed content assertion into PASS.'} else {' Correct the literal argument before replaying the GUI.'}
                            $issues+="Line $($value.Extent.StartLineNumber): '$name -$($parameter.ParameterName)' requires $($attribute.MinRange)..$($attribute.MaxRange).$detail"
                        }
                    }
                }
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

function Test-AGTAScreenshotMetadataExpression {
    param([Management.Automation.Language.Ast]$Expression,[hashtable]$MetadataVariables)
    foreach ($node in @($Expression.FindAll({param($item) $true},$true))) {
        if ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -notin @('Test-Path','Get-Item','gi')) {return $false}
        if ($node -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -notin @('true','false','null') -and -not $MetadataVariables.ContainsKey($node.VariablePath.UserPath)) {return $false}
        if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst]) {return $false}
        if ($node -is [Management.Automation.Language.MemberExpressionAst] -and
            $node.Member.Extent.Text -notin @('Length','Exists','Name','FullName','Extension','LastWriteTime','LastWriteTimeUtc','CreationTime','CreationTimeUtc','Attributes')) {return $false}
        if ($node -is [Management.Automation.Language.TypeExpressionAst] -and $node.TypeName.FullName -notin @('bool','boolean','int','long','double','string')) {return $false}
    }
    return $true
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
