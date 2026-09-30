$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:FrameworkRoot = Split-Path -Parent $script:ModuleRoot
. (Join-Path $PSScriptRoot 'Exploration.ps1')

function Get-AGTAFrameworkRoot {
    [CmdletBinding()]
    param()

    return $script:FrameworkRoot
}

function Resolve-AGTADefaultPotatoCliPath {
    [CmdletBinding()]
    param()

    $candidate = Join-Path -Path (Split-Path -Parent $script:FrameworkRoot) -ChildPath 'potato-cli\potato.ps1'
    if (-not (Test-Path $candidate)) { $candidate = Join-Path (Split-Path -Parent $script:FrameworkRoot) 'potato_cli\potato.ps1' }
    return $candidate
}

function Read-AGTATestCaseCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Testcase CSV not found: $Path"
    }

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $rows = Import-Csv -LiteralPath $resolved
    if (-not $rows) {
        throw "Testcase CSV is empty: $resolved"
    }

    $headers = @($rows[0].PSObject.Properties.Name)
    foreach ($required in @('Action', 'Data', 'Expected Result')) {
        if ($headers -notcontains $required) {
            throw "Testcase CSV must contain '$required'."
        }
    }

    $steps = @()
    $index = 0
    foreach ($row in $rows) {
        $index++
        $stepId = $null
        if ($headers -contains 'StepId' -and $row.StepId) { $stepId = [string]$row.StepId }
        if (-not $stepId) { $stepId = [string]$index }

        $data = ''
        if ($headers -contains 'Data') { $data = [string]$row.Data }

        $application = ''
        if ($headers -contains 'Application') { $application = [string]$row.Application }

        $notes = ''
        if ($headers -contains 'Notes') { $notes = [string]$row.Notes }

        $steps += [pscustomobject][ordered]@{
            stepIndex = $index
            stepId = $stepId
            action = [string]$row.Action
            data = $data
            expectedResult = [string]$row.'Expected Result'
            application = $application
            notes = $notes
            sourcePath = $resolved
        }
    }

    return $steps
}

function New-AGTARunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TestCaseCsv,

        [string] $RunsRoot = (Join-Path -Path (Get-AGTAFrameworkRoot) -ChildPath 'runs'),

        [string] $RunId
    )

    if (-not $RunId) {
        $RunId = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), (New-Guid).Guid
    }

    $runRoot = Join-Path -Path $RunsRoot -ChildPath $RunId
    $paths = [ordered]@{
        runRoot = $runRoot
        input = Join-Path -Path $runRoot -ChildPath 'input'
        generated = Join-Path -Path $runRoot -ChildPath 'generated'
        evidence = Join-Path -Path $runRoot -ChildPath 'evidence'
        logs = Join-Path -Path $runRoot -ChildPath 'logs'
        results = Join-Path -Path $runRoot -ChildPath 'results'
    }

    foreach ($path in $paths.Values) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $TestCaseCsv) {
        Copy-Item -LiteralPath $TestCaseCsv -Destination (Join-Path -Path $paths.input -ChildPath (Split-Path -Leaf $TestCaseCsv)) -Force
    }

    $manifest = [ordered]@{
        runId = $RunId
        createdAt = (Get-Date).ToString('o')
        testCaseCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestCaseCsv)
        paths = $paths
    }
    $manifestPath = Join-Path -Path $paths.runRoot -ChildPath 'run.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return [pscustomobject][ordered]@{
        runId = $RunId
        runRoot = $paths.runRoot
        input = $paths.input
        generated = $paths.generated
        evidence = $paths.evidence
        logs = $paths.logs
        results = $paths.results
        manifestPath = $manifestPath
    }
}

function ConvertFrom-AGTAPotatoJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $RawOutput
    )

    $trimmed = $RawOutput.Trim()
    if (-not $trimmed) {
        throw 'PoTATo CLI returned empty output.'
    }

    try {
        $parsed = $trimmed | ConvertFrom-Json
    }
    catch {
        throw "PoTATo CLI returned invalid JSON. Output: $trimmed"
    }

    if ($null -eq $parsed.ok -or $null -eq $parsed.command) {
        throw 'PoTATo CLI JSON is missing required fields: ok, command.'
    }

    return $parsed
}

function Join-AGTAProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $escaped = foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            '""'
        }
        elseif ($arg -match '[\s"]') {
            $escapedArg = $arg -replace '\\', '\\'
            $escapedArg = $escapedArg -replace '"', '\"'
            '"' + $escapedArg + '"'
        }
        else {
            $arg
        }
    }
    return ($escaped -join ' ')
}

function Invoke-AGTAProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $Arguments = @()
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-AGTAProcessArgument -Arguments $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    return [pscustomobject][ordered]@{
        exitCode = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
        commandLine = "$FilePath $($psi.Arguments)"
    }
}

function Write-AGTAJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Object
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $Object | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Get-AGTAMetricsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunRoot
    )

    Join-Path -Path $RunRoot -ChildPath 'logs\metrics.jsonl'
}

function Write-AGTAMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunRoot,

        [Parameter(Mandatory)]
        [object] $Metric
    )

    try {
        $path = Get-AGTAMetricsPath -RunRoot $RunRoot
        Write-AGTAJsonLine -Path $path -Object $Metric
    }
    catch {
        try {
            $fallback = Join-Path -Path $RunRoot -ChildPath 'logs\metric-errors.log'
            $_.Exception.Message | Add-Content -LiteralPath $fallback -Encoding UTF8
        }
        catch {}
    }
}

function Set-AGTAAuthoringStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [ValidateSet('planning', 'exploration', 'development_iteration')]
        [string] $Stage,

        [Parameter(Mandatory)]
        [string] $Summary,

        [object[]] $Details = @()
    )

    if ($Context.PSObject.Properties.Name -notcontains 'CurrentStage') {
        Add-Member -InputObject $Context -NotePropertyName 'CurrentStage' -NotePropertyValue '' -Force
    }
    if ($Context.PSObject.Properties.Name -notcontains 'StageHistory' -or $null -eq $Context.StageHistory) {
        Add-Member -InputObject $Context -NotePropertyName 'StageHistory' -NotePropertyValue (New-Object System.Collections.ArrayList) -Force
    }

    $previousStage = [string]$Context.CurrentStage
    if ($Stage -eq 'exploration' -and -not (Test-Path (Get-AGTAExplorationPaths $Context.Run.runRoot).manifest)) {
        Initialize-AGTAExploration $Context.Run.runRoot $Context.TestCaseCsv $Context.InteractionPolicy | Out-Null
    }
    if ($Stage -eq 'development_iteration') {
        Complete-AGTAExploration $Context.Run.runRoot $Context.TestCaseCsv $Context.InteractionPolicy | Out-Null
    }
    $detailText = @($Details | ForEach-Object { [string]$_ })
    $record = [pscustomobject][ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = 'authoring_stage'
        previousStage = $previousStage
        stage = $Stage
        summary = $Summary
        details = $detailText
    }

    $Context.CurrentStage = $Stage
    [void]$Context.StageHistory.Add($record)

    $stageLogPath = Join-Path -Path $Context.Run.logs -ChildPath 'authoring-stages.jsonl'
    Write-AGTAJsonLine -Path $stageLogPath -Object $record
    Write-AGTAMetric -RunRoot $Context.Run.runRoot -Metric $record

    return [pscustomobject][ordered]@{
        ok = $true
        stage = $Stage
        previousStage = $previousStage
        stageLogPath = $stageLogPath
        explorationEvidenceRoot = (Get-AGTAExplorationPaths $Context.Run.runRoot).evidenceRoot
        explorationEvidenceRootExists = [IO.Directory]::Exists((Get-AGTAExplorationPaths $Context.Run.runRoot).evidenceRoot)
    }
}

function Assert-AGTAAuthoringStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [string[]] $AllowedStages,

        [Parameter(Mandatory)]
        [string] $ToolName
    )

    $currentStage = ''
    if ($Context.PSObject.Properties.Name -contains 'CurrentStage') {
        $currentStage = [string]$Context.CurrentStage
    }

    if ($currentStage -notin $AllowedStages) {
        throw ("Tool '{0}' requires authoring stage {1}. Current stage is '{2}'. Call set_authoring_stage first." -f $ToolName, ($AllowedStages -join ' or '), $(if ($currentStage) { $currentStage } else { 'unset' }))
    }
}

function Invoke-AGTAPotatoJson {
    [CmdletBinding()]
    param(
        [string] $PotatoCliPath = (Resolve-AGTADefaultPotatoCliPath),

        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [string] $RunRoot,
        [ValidateSet('VisibleControls','GuiNavigation','AllowShortcuts')] [string] $InteractionPolicy = 'GuiNavigation'
    )

    if (-not (Test-Path -LiteralPath $PotatoCliPath)) {
        throw "PoTATo CLI entrypoint not found: $PotatoCliPath"
    }

    $logPath = Join-Path -Path $RunRoot -ChildPath 'logs\potato-commands.jsonl'
    $Arguments=@(Resolve-AGTACommandArguments $Command $Arguments)
    if (@($Arguments | Where-Object { $_ -match '^--?InteractionPolicy(?:=|$)' }).Count) { throw 'Command policy overrides are forbidden.' }
    $Arguments = @($Arguments) + @('-InteractionPolicy', $InteractionPolicy)
    $processArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PotatoCliPath, $Command) + $Arguments
    $startedAt = Get-Date
    $modulePath = Join-Path (Split-Path -Parent $PotatoCliPath) 'PoTAToCli\PoTAToCli.psm1'
    $cliModule = Import-Module $modulePath -PassThru -ErrorAction Stop
    $value = & $cliModule { param($cmd,$values,$root) Invoke-PotatoCliCommand -Command $cmd -Arguments $values -CliRoot $root -AsObject } $Command $Arguments (Split-Path -Parent $PotatoCliPath)
    $processResult = [pscustomobject]@{exitCode=0;stdout=($value | ConvertTo-Json -Depth 80 -Compress);stderr=''}
    $finishedAt = Get-Date

    $record = [ordered]@{
        startedAt = $startedAt.ToString('o')
        finishedAt = $finishedAt.ToString('o')
        command = $Command
        arguments = $Arguments
        exitCode = $processResult.exitCode
        stdout = $processResult.stdout
        stderr = $processResult.stderr
    }

    $parsed = $null
    try {
        $parsed = ConvertFrom-AGTAPotatoJson -RawOutput $processResult.stdout
        $record.parsed = $parsed
    }
    catch {
        $record.parseError = $_.Exception.Message
        Write-AGTAJsonLine -Path $logPath -Object $record
        Write-AGTAMetric -RunRoot $RunRoot -Metric ([ordered]@{
            timestamp = $finishedAt.ToString('o')
            event = 'potato_command'
            command = $Command
            arguments = $Arguments
            ok = $false
            durationMs = [int]($finishedAt - $startedAt).TotalMilliseconds
            exitCode = $processResult.exitCode
            parseError = $_.Exception.Message
        })
        throw
    }

    Write-AGTAJsonLine -Path $logPath -Object $record
    Write-AGTAMetric -RunRoot $RunRoot -Metric ([ordered]@{
        timestamp = $finishedAt.ToString('o')
        event = 'potato_command'
        command = $Command
        arguments = $Arguments
        ok = [bool]$parsed.ok
        durationMs = [int]($finishedAt - $startedAt).TotalMilliseconds
        exitCode = $processResult.exitCode
        potatoRunId = $parsed.session.runId
        errorType = $(if ($parsed.error) { $parsed.error.type } else { $null })
        errorCategory = $(if ($parsed.error) { $parsed.error.category } else { $null })
    })
    return $parsed
}

function New-AGTAStepResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Step,

        [ValidateSet('PASS', 'FAIL', 'SKIPPED')]
        [string] $Status = 'SKIPPED',

        [object[]] $Evidence = @(),

        [object[]] $Commands = @(),

        [object] $ErrorObject = $null
    )

    return [pscustomobject][ordered]@{
        stepIndex = [int]$Step.stepIndex
        action = [string]$Step.action
        expectedResult = [string]$Step.expectedResult
        status = $Status
        evidence = @($Evidence)
        commands = @($Commands)
        error = $ErrorObject
    }
}

function Test-AGTAGeneratedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [object[]] $ExpectedSteps = @()
    )

    $requiredTopLevel = @('ok', 'testCase', 'runRoot', 'startedAt', 'finishedAt', 'steps', 'summary', 'artifacts', 'interactionPolicy')
    foreach ($field in $requiredTopLevel) {
        if ($Result.PSObject.Properties.Name -notcontains $field) { return $false }
    }

    if ($Result.ok -isnot [bool]) { return $false }
    if ($Result.interactionPolicy.mode -notin @('VisibleControls','GuiNavigation','AllowShortcuts')) { return $false }
    if ($Result.ok -and $Result.interactionPolicy.compliant -ne $true) { return $false }
    $steps = @($Result.steps)
    if ($steps.Count -eq 0) { return $false }
    $seen = @{}
    foreach ($step in $steps) {
        foreach ($field in @('stepIndex', 'action', 'expectedResult', 'status', 'evidence', 'commands', 'error')) {
            if ($step.PSObject.Properties.Name -notcontains $field) { return $false }
        }
        if ($step.status -notin @('PASS', 'FAIL', 'SKIPPED')) { return $false }
        if ($step.status -eq 'PASS' -and (-not @($step.assertions).Count -or $null -eq $step.assertions -or @($step.assertions | Where-Object { $_.passed -ne $true }).Count)) { return $false }
        $index = 0
        if (-not [int]::TryParse([string]$step.stepIndex, [ref]$index) -or $index -lt 1 -or $index -gt $steps.Count -or $seen.ContainsKey($index)) { return $false }
        $seen[$index] = $true
    }
    foreach ($pair in @(@{key='passed';status='PASS'}, @{key='failed';status='FAIL'}, @{key='skipped';status='SKIPPED'})) {
        if ($null -eq $Result.summary.($pair.key) -or $Result.summary.($pair.key) -ne @($steps | Where-Object { $_.status -eq $pair.status }).Count) { return $false }
    }
    if ($Result.summary.total -ne $steps.Count) { return $false }
    if ($ExpectedSteps.Count) {
        if ($ExpectedSteps.Count -ne $steps.Count) { return $false }
        foreach ($step in $steps) {
            $expected = $ExpectedSteps[[int]$step.stepIndex - 1]
            if ($step.action -cne $expected.action -or $step.expectedResult -cne $expected.expectedResult) { return $false }
        }
    }
    if ($Result.ok -and (@($steps | Where-Object { $_.status -ne 'PASS' }).Count -gt 0 -or @($Result.cleanup | Where-Object { $null -ne $_ -and $_.ok -ne $true }).Count -gt 0)) { return $false }
    return $true
}

function Get-AGTASystemPrompt {
    [CmdletBinding()]
    param()

    $guide = Get-Content -LiteralPath (Join-Path $script:FrameworkRoot 'docs\AUTHORING.md') -Raw
    $template = Get-Content -LiteralPath (Join-Path $script:FrameworkRoot 'templates\GeneratedScript.Template.ps1') -Raw
    return "Use the provided tools. Call set_authoring_stage for planning, exploration, then development_iteration. run_potato help is allowed during planning. Write and execute scripts only in development_iteration. Read_testcase returns the CSV. Keep desktop commands sequential.`n$guide`nGenerated template:`n$template"

}

function Assert-AGTAAuthoredScriptPreflight {
    param([string] $ScriptPath, [object] $Context)
    . (Join-Path $script:FrameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
    Assert-AGTAGeneratedScriptPreflight -ScriptPath $ScriptPath -TestCaseCsv $Context.TestCaseCsv -PotatoCliPath $Context.PotatoCliPath -ExplorationPath (Get-AGTAExplorationPaths $Context.Run.runRoot).manifest -InteractionPolicy $Context.InteractionPolicy | Out-Null
}

function Get-AGTAUserPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Steps
    )

    $stepJson = $Steps | ConvertTo-Json -Depth 10
    @"
Create a repeatable PowerShell GUI test script for these testcase steps:

$stepJson

First inspect the environment with PoTATo commands as needed. Then write the generated script under the run folder. If execution is available, validate it once and fix concrete issues.

Required stage sequence:
1. Call set_authoring_stage with stage "planning", then read the testcase and produce a plan.
2. Call set_authoring_stage with stage "exploration", then use PoTATo to explore and manually perform the required GUI actions.
3. Call set_authoring_stage with stage "development_iteration", then write, validate, fix, and optimize the generated script.

GuiNavigation is the default: visible GUI routes, file-manager address bars and Open/Open with/double-click, bounded press-key navigation, and audited focused literal typing. Application shortcuts, clipboard, object models, direct expected-output creation, and non-GUI shell/protocol launch wrappers remain forbidden. Preserve an explicitly requested VisibleControls policy. Apply the same policy to exploration and execution.
Start defaults to RequireNewWindow, allowing shared shell/application processes while owning only a new window there. Reuse test windows with focus instead of relaunching. Before a GUI cross-app opening, windows -Checkpoint records a baseline; focus -SinceCheckpoint <checkpointId> registers only the observed new window for cleanup. Plain focus changes the interaction target without owning its host. windows -Foreground returns the actual dialog identity for guarded Scope ForegroundWindow observation/click/type/press-key. External focused typing requires ExpectedFocusJson. PathKind enables readback by default; standard Windows Edit fields support readback and PreDelete even when UIA patterns are missing. Preserve absolute paths and tested pacing. Never replace these routes with launcher wrappers or broad process termination.

The generated script must include end-of-run cleanup. It should register opened processes and created external paths with the shared runtime, close applications/windows it opened, delete fixed-path or external files/state it created that could affect a future run, preserve intentional evidence under the run folder, and record cleanup actions/errors in the final JSON.

During development_iteration, perform an optimization pass after correctness: prefer explicit waits over sleeps, tighten selectors, remove unused exploratory commands, keep evidence capture intentional, and make dialog handling deterministic.

Keep generated-script output compact by using Framework\GeneratedScriptRuntime.ps1. Write only testcase-specific actions/selectors/assertions in the generated script; the runtime writes full PoTATo responses to a per-execution JSONL command log and includes only command summaries in step results.
"@
}

function Get-AGTAOpenAITools {
    [CmdletBinding()]
    param()

    @(
        @{
            type = 'function'
            name = 'set_authoring_stage'
            description = 'Record the current authoring stage. Required before planning, exploration, and development/iteration work.'
            parameters = @{
                type = 'object'
                required = @('stage', 'summary')
                properties = @{
                    stage = @{ type = 'string'; enum = @('planning', 'exploration', 'development_iteration') }
                    summary = @{ type = 'string' }
                    details = @{ type = 'array'; items = @{ type = 'string' } }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'read_testcase'
            description = 'Return the parsed testcase CSV steps.'
            parameters = @{ type = 'object'; properties = @{}; additionalProperties = $false }
        },
        @{
            type = 'function'
            name = 'run_potato'
            description = 'Run an allowlisted PoTATo CLI command and return parsed JSON.'
            parameters = @{
                type = 'object'
                required = @('command')
                properties = @{
                    command = @{ type = 'string' }
                    arguments = @{ type = 'array'; items = @{ type = 'string' } }
                    stepIndex = @{ type = 'integer'; description = 'Required during exploration: CSV row performed by this command.' }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'record_exploration_step'
            description = 'Record a completed CSV row after performing its GUI route and observing its expected result. All rows are required before development.'
            parameters = @{ type='object'; required=@('stepIndex','route','observedResult','verificationCommandId'); additionalProperties=$false;
                properties=@{stepIndex=@{type='integer'};route=@{type='string'};observedResult=@{type='string'};verificationCommandId=@{type='string'};verificationCommandIds=@{type='array';items=@{type='string'}}} }
        },
        @{
            type = 'function'
            name = 'write_generated_script'
            description = 'Write or replace the generated PowerShell script under the run generated folder. The script should dot-source Framework\GeneratedScriptRuntime.ps1 and contain testcase-specific automation only.'
            parameters = @{
                type = 'object'
                required = @('relativePath', 'content')
                properties = @{
                    relativePath = @{ type = 'string' }
                    content = @{ type = 'string' }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'run_generated_script'
            description = 'Run a generated script under the run generated folder.'
            parameters = @{
                type = 'object'
                required = @('relativePath')
                properties = @{ relativePath = @{ type = 'string' } }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'read_artifact'
            description = 'Read a text artifact from the run folder.'
            parameters = @{
                type = 'object'
                required = @('relativePath')
                properties = @{
                    relativePath = @{ type = 'string' }
                    maxChars = @{ type = 'integer' }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'finalize'
            description = 'Finalize authoring with a summary and generated script path.'
            parameters = @{
                type = 'object'
                required = @('summary','scriptPath')
                properties = @{
                    summary = @{ type = 'string' }
                    scriptPath = @{ type = 'string'; description = 'Generated script path, relative to the generated folder or its full path.' }
                }
                additionalProperties = $false
            }
        }
    )
}

function Assert-AGTASafeRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Path must be relative to the run folder: $RelativePath"
    }
    if ($RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Path may not traverse outside the run folder: $RelativePath"
    }

    $combined = Join-Path -Path $Root -ChildPath $RelativePath
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $combinedFull = [System.IO.Path]::GetFullPath($combined)
    if (-not $combinedFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path resolved outside run folder: $RelativePath"
    }
    return $combinedFull
}

function Invoke-AGTAAgentTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [object] $Arguments,

        [Parameter(Mandatory)]
        [object] $Context
    )

    switch ($Name) {
        'set_authoring_stage' {
            $details = @()
            if ($Arguments.details) { $details = @($Arguments.details | ForEach-Object { [string]$_ }) }
            return Set-AGTAAuthoringStage -Context $Context -Stage ([string]$Arguments.stage) -Summary ([string]$Arguments.summary) -Details $details
        }
        'read_testcase' {
            return @{ steps = @($Context.Steps) }
        }
        'run_potato' {
            $command = [string]$Arguments.command
            if ($command -ne 'help') { Assert-AGTAAuthoringStage -Context $Context -AllowedStages @('exploration', 'development_iteration') -ToolName $Name }
            $allowed = @('help','state','windows','start','focus','observe','select','click','click-coordinate','type','hotkey','press-key','drag','hover','wait-element','wait-file','read','read-pdf','screenshot','close-window','report')
            if ($command -notin $allowed) { throw "PoTATo command is not allowed: $command" }
            $args = @()
            if ($Arguments.arguments) { $args = @($Arguments.arguments | ForEach-Object { [string]$_ }) }
            if ($Context.CurrentStage -eq 'exploration' -and $command -ne 'help' -and ($Arguments.stepIndex -lt 1 -or $Arguments.stepIndex -gt $Context.Steps.Count)) { throw 'Exploration requires stepIndex before dispatch.' }
            $result=Invoke-AGTAPotatoJson -PotatoCliPath $Context.PotatoCliPath -Command $command -Arguments $args -RunRoot $Context.Run.runRoot -InteractionPolicy $Context.InteractionPolicy
            if ($Context.CurrentStage -eq 'exploration' -and $command -ne 'help') {
                $id=Add-AGTAExplorationCommand $Context.Run.runRoot $Arguments.stepIndex $command $args $result
                $result | Add-Member -NotePropertyName explorationCommandId -NotePropertyValue $id -Force
                $result | Add-Member -NotePropertyName verification -NotePropertyValue (Get-AGTAExplorationVerificationInfo @{command=$command;result=$result}) -Force
            }
            return $result
        }
        'record_exploration_step' {
            Assert-AGTAAuthoringStage -Context $Context -AllowedStages @('exploration') -ToolName $Name
            return Complete-AGTAExplorationStep $Context.Run.runRoot $Arguments.stepIndex $Arguments.route $Arguments.observedResult $Arguments.verificationCommandId $Arguments.verificationCommandIds
        }
        'write_generated_script' {
            Assert-AGTAAuthoringStage -Context $Context -AllowedStages @('development_iteration') -ToolName $Name
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput([string]$Arguments.content, [ref]$null, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) { throw ('Generated script syntax errors: ' + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }
            $path = Assert-AGTASafeRelativePath -Root $Context.Run.generated -RelativePath ([string]$Arguments.relativePath)
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
            Set-Content -LiteralPath $path -Value ([string]$Arguments.content) -Encoding UTF8
            Assert-AGTAAuthoredScriptPreflight -ScriptPath $path -Context $Context
            return @{ path = $path; relativePath=[string]$Arguments.relativePath; length = ([string]$Arguments.content).Length }
        }
        'run_generated_script' {
            Assert-AGTAAuthoringStage -Context $Context -AllowedStages @('development_iteration') -ToolName $Name
            if (-not $Context.Execute) { return @{ skipped = $true; reason = 'Execution disabled.' } }
            $path = Assert-AGTASafeRelativePath -Root $Context.Run.generated -RelativePath ([string]$Arguments.relativePath)
            if (-not (Test-Path -LiteralPath $path)) { throw "Generated script not found: $path" }
            Assert-AGTAAuthoredScriptPreflight -ScriptPath $path -Context $Context
            $proc = Invoke-AGTAProcess -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path,
                '-PotatoCliPath', $Context.PotatoCliPath,
                '-TestCaseCsv', $Context.TestCaseCsv,
                '-RunRoot', $Context.Run.runRoot,
                '-FrameworkRoot', $script:FrameworkRoot,
                '-InteractionPolicy', $Context.InteractionPolicy,
                '-PolicyReason', $(if ($Context.PolicyReason) { $Context.PolicyReason } else { 'Strict default' })
            )
            $logPath = Join-Path -Path $Context.Run.logs -ChildPath 'generated-script-run.json'
            $proc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $logPath -Encoding UTF8
            $generatedOk = $false
            try {
                $generatedParsed = $proc.stdout.Trim() | ConvertFrom-Json
                $generatedOk = ($proc.exitCode -eq 0 -and (Test-AGTAGeneratedResult -Result $generatedParsed -ExpectedSteps $Context.Steps) -and [bool]$generatedParsed.ok -and $generatedParsed.interactionPolicy.mode -eq $Context.InteractionPolicy)
            }
            catch {}
            $Context | Add-Member -NotePropertyName LastExecution -NotePropertyValue @{ok=$generatedOk;path=$path;hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash} -Force
            Write-AGTAMetric -RunRoot $Context.Run.runRoot -Metric ([ordered]@{
                timestamp = (Get-Date).ToString('o')
                event = 'generated_script_run'
                relativePath = [string]$Arguments.relativePath
                exitCode = $proc.exitCode
                ok = $generatedOk
                stdoutLength = ([string]$proc.stdout).Length
                stderrLength = ([string]$proc.stderr).Length
                logPath = $logPath
            })
            return @{ exitCode = $proc.exitCode; stdout = $proc.stdout; stderr = $proc.stderr; logPath = $logPath }
        }
        'read_artifact' {
            $maxChars = 4000
            if ($Arguments.maxChars) { $maxChars = [int]$Arguments.maxChars }
            $path = Assert-AGTASafeRelativePath -Root $Context.Run.runRoot -RelativePath ([string]$Arguments.relativePath)
            if (-not (Test-Path -LiteralPath $path)) { throw "Artifact not found: $path" }
            $content = Get-Content -LiteralPath $path -Raw
            if ($content.Length -gt $maxChars) { $content = $content.Substring(0, $maxChars) }
            return @{ path = $path; content = $content }
        }
        'finalize' {
            Assert-AGTAAuthoringStage -Context $Context -AllowedStages @('development_iteration') -ToolName $Name
            $seenStages = @($Context.StageHistory | ForEach-Object { [string]$_.stage })
            $missingStages = @('planning', 'exploration', 'development_iteration') | Where-Object { $seenStages -notcontains $_ }
            if ($missingStages.Count -gt 0) {
                throw "Cannot finalize before all authoring stages are recorded. Missing: $($missingStages -join ', ')"
            }
            $requestedPath=[string]$Arguments.scriptPath
            if ([IO.Path]::IsPathRooted($requestedPath)) {
                $prefix=[IO.Path]::GetFullPath($Context.Run.generated).TrimEnd('\')+'\'
                $finalPath=[IO.Path]::GetFullPath($requestedPath)
                if (-not $finalPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Final script must be inside the run generated folder.' }
            } else { $finalPath=Assert-AGTASafeRelativePath -Root $Context.Run.generated -RelativePath $requestedPath }
            Assert-AGTAAuthoredScriptPreflight -ScriptPath $finalPath -Context $Context
            if ($Context.Execute -and (-not $Context.LastExecution.ok -or $Context.LastExecution.path -ne $finalPath -or $Context.LastExecution.hash -ne (Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash)) {
                throw 'Cannot finalize: the current generated script has not passed a complete execution. Report the blocker; do not claim PASS from an older revision.'
            }
            return @{ final = $true; summary = [string]$Arguments.summary; scriptPath = [string]$Arguments.scriptPath }
        }
        default {
            throw "Unknown tool: $Name"
        }
    }
}

function ConvertFrom-AGTAJsonObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return @{} }
    if ($Value -is [string]) {
        if (-not $Value) { return @{} }
        return $Value | ConvertFrom-Json
    }
    return $Value
}

function Get-AGTAResponseText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Response
    )

    if ($Response.output_text) { return [string]$Response.output_text }
    $parts = @()
    foreach ($item in @($Response.output)) {
        foreach ($content in @($item.content)) {
            if ($content.text) { $parts += [string]$content.text }
            elseif ($content.type -eq 'output_text' -and $content.PSObject.Properties.Name -contains 'text') { $parts += [string]$content.text }
        }
    }
    return ($parts -join [Environment]::NewLine)
}

function Get-AGTAFunctionCalls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Response
    )

    $calls = @()
    foreach ($item in @($Response.output)) {
        if ($item.type -in @('function_call', 'tool_call')) {
            $calls += $item
        }
    }
    return $calls
}

function Invoke-AGTAOpenAIAuthoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $Model,

        [int] $MaxIterations = 20,

        [string] $SystemPrompt,

        [string] $UserPrompt
    )

    $apiKey = $env:OPENAI_API_KEY
    if (-not $apiKey) { throw 'OPENAI_API_KEY is not set.' }

    $headers = @{
        Authorization = "Bearer $apiKey"
        'Content-Type' = 'application/json'
    }
    $uri = 'https://api.openai.com/v1/responses'
    $transcriptPath = Join-Path -Path $Context.Run.logs -ChildPath 'openai-responses.jsonl'
    $previousResponseId = $null
    if (-not $SystemPrompt) { $SystemPrompt = Get-AGTASystemPrompt }
    if (-not $UserPrompt) { $UserPrompt = Get-AGTAUserPrompt -Steps $Context.Steps }
    $UserPrompt += "`nResolved run policy: $($Context.InteractionPolicy). Authorization: $($Context.PolicyReason). Use this same policy in generated execution."
    $input = @(
        @{ role = 'user'; content = $UserPrompt }
    )
    $final = $null

    for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
        $body = [ordered]@{
            model = $Model
            instructions = $SystemPrompt
            input = $input
            tools = Get-AGTAOpenAITools
            tool_choice = 'auto'
            parallel_tool_calls = $false
        }
        if ($previousResponseId) {
            $body.previous_response_id = $previousResponseId
        }

        $requestWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ($body | ConvertTo-Json -Depth 80)
        $requestWatch.Stop()
        Write-AGTAJsonLine -Path $transcriptPath -Object @{ iteration = $iteration; response = $response }
        $usage = $response.usage
        Write-AGTAMetric -RunRoot $Context.Run.runRoot -Metric ([ordered]@{
            timestamp = (Get-Date).ToString('o')
            event = 'ai_response'
            provider = 'OpenAI'
            model = $Model
            iteration = $iteration
            responseId = $response.id
            status = $response.status
            durationMs = [int]$requestWatch.ElapsedMilliseconds
            inputTokens = $(if ($usage) { [int]$usage.input_tokens } else { 0 })
            cachedInputTokens = $(if ($usage -and $usage.input_tokens_details) { [int]$usage.input_tokens_details.cached_tokens } else { 0 })
            outputTokens = $(if ($usage) { [int]$usage.output_tokens } else { 0 })
            reasoningTokens = $(if ($usage -and $usage.output_tokens_details) { [int]$usage.output_tokens_details.reasoning_tokens } else { 0 })
            totalTokens = $(if ($usage) { [int]$usage.total_tokens } else { 0 })
        })
        $previousResponseId = $response.id
        $calls = @(Get-AGTAFunctionCalls -Response $response)

        if ($calls.Count -eq 0) {
            $final = [ordered]@{
                provider = 'OpenAI'
                model = $Model
                iterations = $iteration
                outputText = Get-AGTAResponseText -Response $response
                responseId = $response.id
                run = $Context.Run
            }
            break
        }

        $toolOutputs = @()
        foreach ($call in $calls) {
            $arguments = ConvertFrom-AGTAJsonObject -Value $call.arguments
            $toolResult = $null
            try {
                $toolResult = Invoke-AGTAAgentTool -Name ([string]$call.name) -Arguments $arguments -Context $Context
            }
            catch {
                $toolResult = @{ error = $_.Exception.Message }
            }
            $toolOutputs += @{
                type = 'function_call_output'
                call_id = $call.call_id
                output = ($toolResult | ConvertTo-Json -Depth 50 -Compress)
            }
        }
        $input = $toolOutputs
    }

    if (-not $final) {
        throw "OpenAI authoring did not finish within $MaxIterations iterations."
    }
    return $final
}

function Get-AGTAMockScript {
    [CmdletBinding()]
    param()

    $path = Join-Path -Path (Get-AGTAFrameworkRoot) -ChildPath 'templates\GeneratedScript.Template.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Mock template not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Invoke-AGTAMockAuthoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    $scriptText = Get-AGTAMockScript
    [void](Set-AGTAAuthoringStage -Context $Context -Stage 'planning' -Summary 'Mock provider maps CSV rows to incomplete template placeholders.' -Details @(
        'Use the generic incomplete template.',
        'Preserve generated-script contract fields.'
    ))
    [void](Set-AGTAAuthoringStage -Context $Context -Stage 'exploration' -Summary 'Mock provider does not perform live UI exploration.' -Details @(
        'This dry-run path records the stage boundary without touching the desktop.'
    ))
    return [pscustomobject][ordered]@{
        provider = 'Mock'
        incomplete = $true
        scriptPath = $null
        execution = $null
        run = $Context.Run
        summary = 'Mock provider cannot complete GUI exploration. No script was generated or executed; coverage remains incomplete.'
    }
}

function Invoke-AGTAAgentAuthoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TestCaseCsv,

        [ValidateSet('OpenAI', 'Mock')]
        [string] $Provider = 'OpenAI',

        [string] $Model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-5.5' }),

        [string] $PotatoCliPath = (Resolve-AGTADefaultPotatoCliPath),

        [switch] $Execute,

        [int] $MaxIterations = 20,

        [string] $SystemPrompt,

        [string] $UserPrompt,
        [ValidateSet('VisibleControls','GuiNavigation','AllowShortcuts')] [string] $InteractionPolicy = 'GuiNavigation',
        [string] $PolicyReason
    )

    if ($InteractionPolicy -eq 'AllowShortcuts' -and [string]::IsNullOrWhiteSpace($PolicyReason)) { throw 'AllowShortcuts requires PolicyReason identifying user/testcase authorization.' }
    $steps = @(Read-AGTATestCaseCsv -Path $TestCaseCsv)
    $run = New-AGTARunDirectory -TestCaseCsv $TestCaseCsv
    $context = [pscustomobject][ordered]@{
        TestCaseCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestCaseCsv)
        Steps = $steps
        Run = $run
        PotatoCliPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PotatoCliPath)
        InteractionPolicy = $InteractionPolicy
        PolicyReason = $PolicyReason
        Execute = [bool]$Execute
        CurrentStage = ''
        StageHistory = (New-Object System.Collections.ArrayList)
    }

    $authoringStartedAt = Get-Date
    Write-AGTAMetric -RunRoot $run.runRoot -Metric ([ordered]@{
        timestamp = $authoringStartedAt.ToString('o')
        event = 'authoring_start'
        provider = $Provider
        model = $Model
        execute = [bool]$Execute
        stepCount = $steps.Count
        testCaseCsv = $context.TestCaseCsv
    })

    $result = $null
    $authoringError = $null
    try {
        switch ($Provider) {
            'Mock' { $result = Invoke-AGTAMockAuthoring -Context $context }
            'OpenAI' {
                $result = Invoke-AGTAOpenAIAuthoring `
                    -Context $context `
                    -Model $Model `
                    -MaxIterations $MaxIterations `
                    -SystemPrompt $SystemPrompt `
                    -UserPrompt $UserPrompt
            }
        }
    }
    catch {
        $authoringError = $_.Exception.Message
        throw
    }
    finally {
        $authoringFinishedAt = Get-Date
        Write-AGTAMetric -RunRoot $run.runRoot -Metric ([ordered]@{
            timestamp = $authoringFinishedAt.ToString('o')
            event = 'authoring_end'
            provider = $Provider
            model = $Model
            ok = (-not $authoringError -and -not $result.incomplete)
            durationMs = [int]($authoringFinishedAt - $authoringStartedAt).TotalMilliseconds
            resultType = $(if ($result) { $result.GetType().FullName } else { $null })
            error = $authoringError
        })
    }

    $resultPath = Join-Path -Path $run.results -ChildPath 'authoring-result.json'
    $result | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    return [pscustomobject][ordered]@{
        ok = (-not $result.incomplete)
        provider = $Provider
        model = $Model
        runRoot = $run.runRoot
        resultPath = $resultPath
        result = $result
    }
}

Export-ModuleMember -Function `
    Get-AGTAFrameworkRoot, `
    Resolve-AGTADefaultPotatoCliPath, `
    Read-AGTATestCaseCsv, `
    New-AGTARunDirectory, `
    ConvertFrom-AGTAPotatoJson, `
    Invoke-AGTAPotatoJson, `
    New-AGTAStepResult, `
    Test-AGTAGeneratedResult, `
    Get-AGTASystemPrompt, `
    Invoke-AGTAAgentAuthoring, `
    Invoke-AGTAAgentTool, `
    Get-AGTAOpenAITools
Export-ModuleMember -Function Get-AGTAExplorationPaths, Initialize-AGTAExploration, Add-AGTAExplorationCommand, Complete-AGTAExplorationStep, Complete-AGTAExploration, Test-AGTAExploration, Test-AGTAExplorationCommandSucceeded, Get-AGTAExplorationStatus, Get-AGTAExplorationVerificationInfo
