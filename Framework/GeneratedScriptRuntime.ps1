. (Join-Path $PSScriptRoot 'ArtifactAssertions.ps1')
. (Join-Path $PSScriptRoot 'GeneratedScriptPreflight.ps1')
function Initialize-AGTAGeneratedTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PotatoCliPath,

        [Parameter(Mandatory)]
        [string] $TestCaseCsv,

        [Parameter(Mandatory)]
        [string] $RunRoot,

        [string] $ExecutionId = (Get-Date -Format 'yyyyMMdd_HHmmss_ffff'),

        [switch] $RequireAssertions = $true,
        [ValidateSet('VisibleControls','GuiNavigation','AllowShortcuts')] [string] $InteractionPolicy = 'GuiNavigation',
        [string] $PolicyReason,
        [string] $ExplorationPath,
        [ValidateSet('InProcess','Process')] [string] $Transport = 'InProcess'
    )

    # PowerShell's current location can differ from the process current directory.
    # GUI filename fields need absolute filesystem paths in either transport.
    $RunRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
    $PotatoCliPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PotatoCliPath)
    $TestCaseCsv=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestCaseCsv)
    if ($ExplorationPath) { $ExplorationPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExplorationPath) }
    if (-not (Test-Path -LiteralPath $PotatoCliPath)) {
        throw "PoTATo CLI was not found: $PotatoCliPath"
    }
    if (-not (Test-Path -LiteralPath $TestCaseCsv)) {
        throw "Testcase CSV was not found: $TestCaseCsv"
    }

    if ($InteractionPolicy -eq 'AllowShortcuts' -and [string]::IsNullOrWhiteSpace($PolicyReason)) { throw 'AllowShortcuts requires PolicyReason recording the user/testcase authorization.' }
    # Recheck the actual calling script so omitting a standalone preflight does
    # not silently bless direct COM/native-input/data fabrication as compliant.
    $callerPath=$MyInvocation.ScriptName
    $scriptAudit=$null
    if ($callerPath -and (Test-Path -LiteralPath $callerPath -PathType Leaf)) {
        $scriptAudit=Test-AGTAGeneratedScript -ScriptPath $callerPath -InteractionPolicy $InteractionPolicy -PolicyOnly
        if (-not $scriptAudit.ok) { throw ('Generated script audit failed before desktop use: '+($scriptAudit.issues -join '; ')) }
    }
    if (-not $ExplorationPath) { $ExplorationPath=Join-Path $RunRoot 'logs\exploration.json' }
    $exploration=Test-AGTAExploration -Path $ExplorationPath -TestCaseCsv $TestCaseCsv -InteractionPolicy $InteractionPolicy
    if (-not $exploration.ok) { throw ('Complete GUI exploration is required before execution: '+($exploration.issues -join '; ')) }
    $cliModule = $null
    if ($Transport -eq 'InProcess') {
        $modulePath = Join-Path (Split-Path -Parent $PotatoCliPath) 'PoTAToCli\PoTAToCli.psm1'
        $cliModule = Import-Module $modulePath -PassThru -ErrorAction Stop
    }
    $steps = @(Import-Csv -LiteralPath $TestCaseCsv)
    if ($steps.Count -eq 0) { throw 'Testcase CSV must contain at least one step.' }
    foreach ($column in @('Action', 'Data', 'Expected Result')) {
        if ($steps[0].PSObject.Properties.Name -notcontains $column) { throw "Testcase CSV must contain '$column'." }
    }
    $startedAt = Get-Date
    $testCaseName = Split-Path -Leaf $TestCaseCsv
    $evidenceRoot = Join-Path -Path $RunRoot -ChildPath 'evidence'
    $logsRoot = Join-Path -Path $RunRoot -ChildPath 'logs'
    $resultsRoot = Join-Path -Path $RunRoot -ChildPath 'results'
    $executionEvidenceRoot = Join-Path -Path $evidenceRoot -ChildPath $ExecutionId
    $commandLogPath = Join-Path -Path $logsRoot -ChildPath ("potato-commands-$ExecutionId.jsonl")
    $resultPath = Join-Path -Path $resultsRoot -ChildPath 'result.json'

    foreach ($path in @($RunRoot, $evidenceRoot, $logsRoot, $resultsRoot, $executionEvidenceRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    $script:AGTAGeneratedTestContext = [pscustomobject][ordered]@{
        PotatoCliPath = $PotatoCliPath
        TestCaseCsv = $TestCaseCsv
        TestCaseName = $testCaseName
        RunRoot = $RunRoot
        EvidenceRoot = $evidenceRoot
        LogsRoot = $logsRoot
        ResultsRoot = $resultsRoot
        ExecutionEvidenceRoot = $executionEvidenceRoot
        CommandLogPath = $commandLogPath
        ResultPath = $resultPath
        ExecutionId = $ExecutionId
        StartedAt = $startedAt
        Steps = $steps
        RequireAssertions = [bool]$RequireAssertions
        InteractionPolicy = $InteractionPolicy
        PolicyReason = $PolicyReason
        PolicyCompliant = $true
        ScriptAudit = $scriptAudit
        ExplorationPath = $ExplorationPath
        Transport = $Transport
        CliModule = $cliModule
        Timing = [ordered]@{ commandCount=0; wrapperMs=0L; backendMs=0L; waitMs=0L; cleanupMs=0L }
        LastCommandTiming = $null
        FinalOk = $false
    }
    $script:AGTAOpenedProcessNames = @()
    $script:AGTACreatedExternalPaths = @()
    $script:AGTACommandIndex = 0

    return $script:AGTAGeneratedTestContext
}

function Get-AGTAGeneratedTestContext {
    [CmdletBinding()]
    param()

    if (-not $script:AGTAGeneratedTestContext) {
        throw 'Generated test runtime is not initialized. Call Initialize-AGTAGeneratedTest first.'
    }
    return $script:AGTAGeneratedTestContext
}

function ConvertFrom-PotatoOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RawOutput
    )

    try {
        return ($RawOutput.Trim() | ConvertFrom-Json)
    }
    catch {
        throw "PoTATo command did not return valid JSON. Output: $RawOutput"
    }
}

function Invoke-PotatoJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @()
    )

    $context = Get-AGTAGeneratedTestContext
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $Arguments=@(Resolve-AGTACommandArguments $Command $Arguments)
    $raw = @()
    $exitCode = 0
    # The run policy is fixed at initialization, including cleanup and exploration helpers.
    if (@($Arguments | Where-Object { $_ -match '^--?InteractionPolicy(?:=|$)' }).Count) {
        $context.PolicyCompliant = $false
        throw 'Per-command InteractionPolicy overrides are forbidden. Use the declared run policy.'
    }
    $effectiveArgs = @($Arguments) + @('-InteractionPolicy', $context.InteractionPolicy)
    if ($Command -eq 'start') { $effectiveArgs += @('-RequireNewProcess', 'true') }
    $parsed = $null
    try {
        if ($context.Transport -eq 'InProcess') {
            $parsed = & $context.CliModule { param($cmd,$values,$root) Invoke-PotatoCliCommand -Command $cmd -Arguments $values -CliRoot $root -AsObject } $Command $effectiveArgs (Split-Path -Parent $context.PotatoCliPath)
            $raw = @($parsed | ConvertTo-Json -Depth 80 -Compress)
        }
        else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $context.PotatoCliPath $Command @effectiveArgs 2>&1 | ForEach-Object { $raw += $_ }
            $exitCode = $LASTEXITCODE
            $parsed = ConvertFrom-PotatoOutput -RawOutput (@($raw) -join [Environment]::NewLine)
            if ($exitCode -ne 0 -and $parsed.ok) { throw "Process status disagrees with successful JSON: $exitCode" }
        }
    }
    catch {
        $raw += $_.ToString(); $exitCode = 1
        $parsed = [pscustomobject]@{
            ok=$false;command=$Command;data=$null;durationMs=0;outcome='unknown'
            error=@{message="PoTATo transport failed; observe the postcondition before retrying. $($_.Exception.Message)";type='TransportError'}
        }
    }
    $watch.Stop()
    $rawText = @($raw) -join [Environment]::NewLine
    if ($parsed.error.type -eq 'InteractionPolicyViolation') { $context.PolicyCompliant = $false }
    $context.LastCommandTiming = @{wrapperMs=[long]$watch.ElapsedMilliseconds;backendMs=[long]$parsed.durationMs}
    $context.Timing.commandCount++
    $context.Timing.wrapperMs += $watch.ElapsedMilliseconds
    $context.Timing.backendMs += [long]$parsed.durationMs
    if ($Command -in @('wait-file','wait-element')) { $context.Timing.waitMs += [long]$parsed.durationMs }

    if ($Command -eq 'start' -and $parsed.ok -and $parsed.data.ownedProcessId) { Register-OpenedProcess -StartResult $parsed }
    $script:AGTACommandIndex++
    [ordered]@{
        index = $script:AGTACommandIndex
        timestamp = (Get-Date).ToString('o')
        command = $Command
        arguments = @($Arguments)
        raw = $rawText
        parsed = $parsed
        wrapperDurationMs = [int]$watch.ElapsedMilliseconds
        transport = $context.Transport
        interactionPolicy = $context.InteractionPolicy
        exitCode = $exitCode
    } | ConvertTo-Json -Depth 80 -Compress | Add-Content -LiteralPath $context.CommandLogPath -Encoding UTF8 -ErrorAction Stop

    return $parsed
}

function New-CommandSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [object] $Result
    )

    $context = Get-AGTAGeneratedTestContext
    [pscustomobject][ordered]@{
        index = $script:AGTACommandIndex
        command = $Command
        arguments = @($Arguments)
        ok = [bool]$Result.ok
        durationMs = [int]$Result.durationMs
        wrapperDurationMs = $context.LastCommandTiming.wrapperMs
        outcome = $Result.outcome
        interactionPolicy = $Result.interactionPolicy
        logPath = $context.CommandLogPath
        error = $(if ($Result.error) { $Result.error.message } else { $null })
        errorType = $(if ($Result.error) { $Result.error.type } else { $null })
        inputFocus = $(if ($Result.error.focus) { $Result.error.focus } elseif ($Result.data.inputFocus) { $Result.data.inputFocus } else { $null })
    }
}

function Invoke-StepCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @()
    )

    $result = Invoke-PotatoJson -Command $Command -Arguments $Arguments
    $Commands.Value = @($Commands.Value) + (New-CommandSummary -Command $Command -Arguments $Arguments -Result $result)
    return $result
}

function Invoke-StepClick {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ref] $Commands,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [ValidateSet('Auto','Mouse','Invoke')] [string] $Method = 'Auto',
        [string] $Message = 'Visible click failed.'
    )

    if ($Arguments -contains '-Method') { throw 'Pass -Method to Invoke-StepClick, not inside -Arguments.' }
    $result = Invoke-StepCommand -Commands $Commands -Command 'click' -Arguments (@($Arguments) + @('-Method', $Method))
    Assert-PotatoOk -Result $result -Message $Message
    Assert-ExpectedResult -Condition ([bool]$result.data.clicked) -Message $Message
    return $result
}

function Assert-PotatoOk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Message = 'PoTATo command failed.'
    )

    if (-not [bool]$Result.ok -or ($Result.data.verificationPerformed -and $Result.data.verified -eq $false)) {
        $detail = if ($Result.error) { $Result.error.message } else { 'No error detail returned.' }
        throw "$Message $detail"
    }
}

function Test-PotatoFound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    if (-not [bool]$Result.ok) { return $false }
    if ($null -ne $Result.data.exists) { return [bool]$Result.data.exists }
    if ($null -ne $Result.data.count) { return ([int]$Result.data.count -gt 0) }
    if ($null -ne $Result.data.element) { return $true }
    if ($null -ne $Result.data.selected) { return $true }
    return $false
}

function Assert-PotatoFound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Message = 'Expected GUI element was not found.'
    )

    Assert-PotatoOk -Result $Result -Message $Message
    Assert-ExpectedResult -Condition (Test-PotatoFound -Result $Result) -Message $Message
}

function Assert-FileWait {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Path,

        [string] $Message
    )

    $targetPath = if ($Path) { $Path } elseif ($Result.data.path) { [string]$Result.data.path } else { '<unknown path>' }
    $failureMessage = if ($Message) { $Message } else { "File condition must be met: $targetPath" }
    Assert-PotatoOk -Result $Result -Message $failureMessage
    $conditionMet = $false
    if ($null -ne $Result.data.conditionMet) { $conditionMet = [bool]$Result.data.conditionMet }
    elseif ($null -ne $Result.data.exists) { $conditionMet = [bool]$Result.data.exists }
    Assert-ExpectedResult -Condition $conditionMet -Message $failureMessage
}

function Assert-ExpectedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )
    $script:AGTAStepAssertions = @($script:AGTAStepAssertions) + [pscustomobject]@{ description = $Message; passed = $Condition }
    if (-not $Condition) { throw $Message }
}

function Add-EvidencePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Evidence,

        [string] $Path
    )

    if ($Path) {
        $Evidence.Value = @($Evidence.Value) + $Path
    }
}

function Invoke-EvidenceScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [Parameter(Mandatory)]
        [ref] $Evidence,

        [Parameter(Mandatory)]
        [string] $FileName
    )

    $context = Get-AGTAGeneratedTestContext
    $path = Join-Path -Path $context.ExecutionEvidenceRoot -ChildPath $FileName
    $shot = Invoke-StepCommand -Commands $Commands -Command 'screenshot' -Arguments @('-OutFile', $path)
    Assert-PotatoOk -Result $shot -Message 'Screenshot capture failed.'
    Add-EvidencePath -Evidence $Evidence -Path $shot.data.path
    return $shot
}

function Invoke-ClickAny {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [Parameter(Mandatory)]
        [string[]] $Names,

        [string] $ControlType = 'Button',

        [int] $TimeoutMs = 3000
    )

    $last = $null
    foreach ($name in $Names) {
        $arguments = @('-Name', $name, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
        if ($ControlType) {
            $arguments += @('-ControlType', $ControlType)
        }
        $last = Invoke-StepCommand -Commands $Commands -Command 'click' -Arguments $arguments
        if ($last.ok -and $last.data.clicked) {
            return $last
        }
    }
    return $last
}

function Register-OpenedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $StartResult)
    Assert-PotatoOk $StartResult
    $ownedId = $StartResult.data.ownedProcessId
    if (-not $ownedId) { throw 'Start returned no ownedProcessId. Invoke-StepCommand registers valid ownership automatically; inspect the start result instead of bypassing scoped cleanup.' }
    $owned = Get-Process -Id $ownedId -ErrorAction Stop
    if (@($script:AGTAOpenedProcessNames | Where-Object { $_.Id -eq $owned.Id -and $_.StartTime -eq $owned.StartTime }).Count) { return }
    $script:AGTAOpenedProcessNames += [pscustomobject]@{Id=$owned.Id;StartTime=$owned.StartTime}
}

function Register-CreatedExternalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($script:AGTACreatedExternalPaths -notcontains $Path) {
        $script:AGTACreatedExternalPaths += $Path
    }
}

function Test-IsPathUnderRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    return ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

function Invoke-OptionalCleanupClick {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Names,

        [string] $ControlType = 'Button',

        [int] $TimeoutMs = 0,
        [Parameter(Mandatory)] [int] $ProcessId
    )

    foreach ($name in $Names) {
        try {
            $selectArgs = @('-ProcessId', "$ProcessId", '-ModalOnly', 'true', '-Name', $name, '-ControlType', $ControlType, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
            $found = Invoke-PotatoJson -Command 'select' -Arguments $selectArgs
            if (Test-PotatoFound -Result $found) {
                $clickArgs = @('-ProcessId', "$ProcessId", '-ModalOnly', 'true', '-Name', $name, '-ControlType', $ControlType, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
                $clicked = Invoke-PotatoJson -Command 'click' -Arguments $clickArgs
                return [pscustomobject][ordered]@{
                    action = 'optional-click'
                    target = $name
                    ok = [bool]$clicked.ok
                    error = $(if ($clicked.error) { $clicked.error.message } else { $null })
                }
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                action = 'optional-click'
                target = $name
                ok = $false
                error = $_.Exception.Message
            }
        }
    }
    return $null
}

function Invoke-TestCleanup {
    [CmdletBinding()]
    param(
        [string[]] $DiscardPromptNames = @("Don't Save", 'Do Not Save', 'No'),

        [string] $DiscardPromptControlType = 'Button',

        [int] $CloseTimeoutMs = 2500,

        [int] $PromptTimeoutMs = 600
    )

    $context = Get-AGTAGeneratedTestContext
    $records = @()

    $cleanupWatch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($owned in $script:AGTAOpenedProcessNames) {
        try {
            $live = Get-Process -Id $owned.Id -ErrorAction SilentlyContinue
            if (-not $live -or $live.StartTime -ne $owned.StartTime) { continue }
            $closed = Invoke-PotatoJson 'close-window' @('-ProcessId', "$($owned.Id)", '-TimeoutMs', '0')
            Assert-PotatoOk $closed
            # Read top-level windows from the desktop, not descendants of the
            # previously focused document (dialogs are often sibling windows).
            $afterClose = Invoke-PotatoJson 'windows' @('-ProcessId', "$($owned.Id)", '-TimeoutMs', '0')
            Assert-PotatoOk $afterClose
            if (@($afterClose.data.windows | Where-Object { $_.isModal }).Count) {
                $discard = Invoke-OptionalCleanupClick -Names $DiscardPromptNames -ControlType $DiscardPromptControlType -TimeoutMs 0 -ProcessId $owned.Id
                if ($discard) { $records += $discard }
            }
            $until = [Diagnostics.Stopwatch]::StartNew()
            $closePasses = 1
            do {
                $remaining = Invoke-PotatoJson 'windows' @('-ProcessId', "$($owned.Id)", '-TimeoutMs','0')
                Assert-PotatoOk $remaining
                if ($remaining.data.count -eq 0) { break }
                # A native dialog can close asynchronously after its disabled
                # parent rejected the first Close request. Rediscover before
                # retrying only this id/start-time-owned application's windows.
                if ($closePasses -lt 3 -and $until.ElapsedMilliseconds -lt $CloseTimeoutMs) {
                    $live = Get-Process -Id $owned.Id -ErrorAction SilentlyContinue
                    if (-not $live -or $live.StartTime -ne $owned.StartTime) {
                        # The original process exited after the window snapshot.
                        # A reused PID belongs to somebody else; never close it.
                        $remaining=[pscustomobject]@{data=@{count=0;windows=@()}}
                        break
                    }
                    $closed = Invoke-PotatoJson 'close-window' @('-ProcessId', "$($owned.Id)", '-TimeoutMs','0')
                    Assert-PotatoOk $closed
                    $closePasses++
                }
                Start-Sleep -Milliseconds 100
            } while ($until.ElapsedMilliseconds -lt $CloseTimeoutMs)
            if ($remaining.data.count -gt 0) {
                # The last Close can complete while its provider call consumes
                # the remaining deadline. Report a fresh state, not that stale view.
                $live=Get-Process -Id $owned.Id -ErrorAction SilentlyContinue
                if (-not $live -or $live.StartTime -ne $owned.StartTime) {
                    $remaining=[pscustomobject]@{data=@{count=0;windows=@()}}
                } else {
                    $remaining=Invoke-PotatoJson 'windows' @('-ProcessId', "$($owned.Id)", '-TimeoutMs','0')
                    Assert-PotatoOk $remaining
                }
            }
            $records += [pscustomobject]@{action='close-owned-process';target=$owned.Id;ok=($remaining.data.count -eq 0);error=$(if ($remaining.data.count) {'Owned windows remain open.'} else {$null})}
        }
        catch { $records += [pscustomobject]@{action='close-owned-process';target=$owned.Id;ok=$false;error=$_.Exception.Message} }
    }

    foreach ($path in @($script:AGTACreatedExternalPaths | Select-Object -Unique)) {
        try {
            if (Test-IsPathUnderRoot -Path $path -Root $context.RunRoot) {
                $records += [pscustomobject][ordered]@{
                    action = 'preserve-run-artifact'
                    target = $path
                    ok = $true
                    error = $null
                }
                continue
            }
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
            $records += [pscustomobject][ordered]@{
                action = 'delete-created-path'
                target = $path
                ok = $true
                error = $null
            }
        }
        catch {
            $records += [pscustomobject][ordered]@{
                action = 'delete-created-path'
                target = $path
                ok = $false
                error = $_.Exception.Message
            }
        }
    }

    try {
        $pendingOwned = @($records | Where-Object { $_.action -eq 'close-owned-process' -and -not $_.ok })
        if ($pendingOwned.Count) {
            $records += [pscustomobject]@{action='preserve-potato-state';target='session';ok=$true;error=$null}
        } else {
            $result = Invoke-PotatoJson -Command 'state' -Arguments @('-Clear')
            $records += [pscustomobject][ordered]@{
                action = 'clear-potato-state'
                target = 'session'
                ok = [bool]$result.ok
                error = $(if ($result.error) { $result.error.message } else { $null })
            }
        }
    }
    catch {
        $records += [pscustomobject][ordered]@{
            action = 'clear-potato-state'
            target = 'session'
            ok = $false
            error = $_.Exception.Message
        }
    }

    $context.Timing.cleanupMs += $cleanupWatch.ElapsedMilliseconds
    return $records
}

function New-StepResult {
    [CmdletBinding()]
    param(
        [int] $StepIndex,

        [string] $Action,

        [string] $ExpectedResult,

        [ValidateSet('PASS', 'FAIL', 'SKIPPED')]
        [string] $Status,

        [object[]] $Evidence = @(),

        [object[]] $Commands = @(),

        [object] $ErrorObject = $null
    )

    [pscustomobject][ordered]@{
        stepIndex = $StepIndex
        action = $Action
        expectedResult = $ExpectedResult
        status = $Status
        evidence = @($Evidence)
        commands = @($Commands)
        error = $ErrorObject
    }
}

function Get-TestStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $StepIndex
    )

    $context = Get-AGTAGeneratedTestContext
    if ($StepIndex -gt 0 -and $StepIndex -le $context.Steps.Count) {
        return $context.Steps[$StepIndex - 1]
    }

    return [pscustomobject][ordered]@{
        Action = "Step $StepIndex"
        'Expected Result' = ''
    }
}

function Invoke-RecordedStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $StepIndex,

        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    $step = Get-TestStep -StepIndex $StepIndex
    $commands = @()
    $evidence = @()
    $script:AGTAStepAssertions = @()

    try {
        & $Body ([ref]$commands) ([ref]$evidence) | Out-Null
        if ((Get-AGTAGeneratedTestContext).RequireAssertions -and $script:AGTAStepAssertions.Count -eq 0) {
            throw 'No expected-result assertion was recorded. Command success or a screenshot alone cannot pass a step.'
        }
        if (@($script:AGTAStepAssertions | Where-Object { -not $_.passed }).Count) { throw 'An expected-result assertion failed.' }
        $result = New-StepResult -StepIndex $StepIndex -Action $step.Action -ExpectedResult $step.'Expected Result' -Status 'PASS' -Evidence $evidence -Commands $commands
    }
    catch {
        $failure = $_.Exception.Message
        # Preserve the failing state before cleanup; a capture error must not mask it.
        try { Invoke-EvidenceScreenshot -Commands ([ref]$commands) -Evidence ([ref]$evidence) -FileName ("step-{0}-failure.png" -f $StepIndex) | Out-Null } catch {}
        $result = New-StepResult -StepIndex $StepIndex -Action $step.Action -ExpectedResult $step.'Expected Result' -Status 'FAIL' -Evidence $evidence -Commands $commands -ErrorObject $failure
    }
    $result | Add-Member -NotePropertyName assertions -NotePropertyValue @($script:AGTAStepAssertions)
    return $result
}

function Complete-AGTAGeneratedTest {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $StepResults = @(),

        [AllowEmptyCollection()]
        [object[]] $Cleanup = @(),

        [switch] $AllowSkipped,

        [object] $ExtraArtifacts = $null,
        [switch] $PassThru
    )

    $context = Get-AGTAGeneratedTestContext
    $summary = [ordered]@{
        total = @($StepResults).Count
        passed = @($StepResults | Where-Object { $_.status -eq 'PASS' }).Count
        failed = @($StepResults | Where-Object { $_.status -eq 'FAIL' }).Count
        skipped = @($StepResults | Where-Object { $_.status -eq 'SKIPPED' }).Count
    }

    $artifacts = [ordered]@{
        resultPath = $context.ResultPath
        evidenceRoot = $context.EvidenceRoot
        executionEvidenceRoot = $context.ExecutionEvidenceRoot
        commandLogPath = $context.CommandLogPath
        cleanup = @($Cleanup)
        explorationPath = $context.ExplorationPath
    }
    $extraArtifactTable = @{}
    if ($ExtraArtifacts -is [hashtable]) {
        $extraArtifactTable = $ExtraArtifacts
    }
    elseif ($ExtraArtifacts -and $ExtraArtifacts -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $ExtraArtifacts.Keys) {
            $extraArtifactTable[$key] = $ExtraArtifacts[$key]
        }
    }
    foreach ($key in @($extraArtifactTable.Keys)) {
        $artifacts[$key] = $extraArtifactTable[$key]
    }

    $coverageOk = ($summary.total -eq $context.Steps.Count)
    for ($index = 1; $index -le $context.Steps.Count; $index++) {
        if (@($StepResults | Where-Object { $_.stepIndex -eq $index -and $_.action -ceq $context.Steps[$index - 1].Action -and $_.expectedResult -ceq $context.Steps[$index - 1].'Expected Result' }).Count -ne 1) { $coverageOk = $false }
    }
    $validStatuses = @($StepResults | Where-Object { $_.status -notin @('PASS', 'FAIL', 'SKIPPED') }).Count -eq 0
    $cleanupOk = @($Cleanup | Where-Object { $_.ok -ne $true }).Count -eq 0
    $summary.cleanupOk=$cleanupOk
    $summary.failedSteps=@($StepResults | Where-Object {$_.status -eq 'FAIL'} | ForEach-Object { @{stepIndex=$_.stepIndex;error=$_.error} })
    $assertionsOk = $true
    if ($context.RequireAssertions) {
        foreach ($step in $StepResults) {
            if ($step.status -eq 'PASS' -and (@($step.assertions).Count -eq 0 -or $null -eq $step.assertions -or @($step.assertions | Where-Object { $_.passed -ne $true }).Count -gt 0)) { $assertionsOk = $false }
        }
    }
    $ok = ($context.PolicyCompliant -and $coverageOk -and $validStatuses -and $cleanupOk -and $assertionsOk -and $summary.failed -eq 0 -and $summary.skipped -eq 0)
    $final = [ordered]@{
        ok = $ok
        summary = $summary
        cleanupOk = $cleanupOk
        interactionPolicy = @{ mode=$context.InteractionPolicy; reason=$context.PolicyReason; compliant=$context.PolicyCompliant; assessment='Recorded CLI policy and static script checks; external activity is not sandboxed.'; scriptAuditPerformed=($null -ne $context.ScriptAudit) }
        transport = $context.Transport
        timing = $context.Timing
        testCase = $context.TestCaseName
        runRoot = $context.RunRoot
        executionId = $context.ExecutionId
        startedAt = $context.StartedAt.ToString('o')
        finishedAt = (Get-Date).ToString('o')
        steps = @($StepResults)
        artifacts = $artifacts
        cleanup = @($Cleanup)
        coverageOk = $coverageOk
        assertionsOk = $assertionsOk
    }

    $context.FinalOk = $ok
    $context.Timing.totalMs = [long]((Get-Date) - $context.StartedAt).TotalMilliseconds
    $context.Timing.commandOverheadMs = $context.Timing.wrapperMs - $context.Timing.backendMs
    $context.Timing.otherMs = $context.Timing.totalMs - $context.Timing.wrapperMs
    $final | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $context.ResultPath -Encoding UTF8
    if ($PassThru) { return [pscustomobject]$final }
    $final | ConvertTo-Json -Depth 80 -Compress
}

function Invoke-AGTATestPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock[]]$StepBodies, [switch]$PassThru)
    $context=Get-AGTAGeneratedTestContext
    if ($StepBodies.Count -ne $context.Steps.Count -or @($StepBodies | Where-Object {$null -eq $_}).Count) {
        throw 'Test plan must contain exactly one non-null body per CSV row, in order, before any GUI action.'
    }
    $results=@()
    $cleanup=@()
    $blocked=$false
    try {
        for ($i=0; $i -lt $StepBodies.Count; $i++) {
            if ($blocked) {
                $step=$context.Steps[$i]
                $results+=New-StepResult -StepIndex ($i+1) -Action $step.Action -ExpectedResult $step.'Expected Result' -Status SKIPPED -ErrorObject 'A preceding dependent step failed.'
                continue
            }
            $result=Invoke-RecordedStep -StepIndex ($i+1) -Body $StepBodies[$i]
            $results+=$result
            $blocked=$result.status -ne 'PASS'
        }
    } finally {
        $cleanup=@(Invoke-TestCleanup)
        Complete-AGTAGeneratedTest -StepResults $results -Cleanup $cleanup -PassThru:$PassThru
    }
}

function Get-AGTATestExitCode {
    if ((Get-AGTAGeneratedTestContext).FinalOk) { return 0 }; return 1
}
