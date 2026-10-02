# A plan lives in its own module scope: variables, helper functions, CLI scope,
# window ownership and output paths survive tool calls. Never reload setup on repair.
function Get-AGTAPlanDefinition {
    param([string]$ScriptPath)
    $tokens=$null;$errors=$null
    $bytes=[IO.File]::ReadAllBytes($ScriptPath)
    $reader=[IO.StreamReader]::new([IO.MemoryStream]::new($bytes),[Text.Encoding]::UTF8,$true)
    try {$source=$reader.ReadToEnd()} finally {$reader.Dispose()}
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,$ScriptPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {throw ($errors.Message -join '; ')}
    if ($ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock) {throw 'A live plan needs the template end-block layout.'}
    $assignments=@($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and $_.Left.VariablePath.UserPath -eq 'StepBodies'
    })
    if ($assignments.Count -ne 1) {throw 'Use one top-level $StepBodies = @(...) assignment from the template.'}
    $assignment=$assignments[0]
    $array=$assignment.Right.Expression
    if ($array -isnot [Management.Automation.Language.ArrayExpressionAst]) {throw 'StepBodies must be a literal array of scriptblocks.'}
    $bodies=@(foreach ($statement in $array.SubExpression.Statements) {
        if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or
            $statement.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {throw 'StepBodies may contain only literal scriptblocks.'}
        $expression=$statement.PipelineElements[0].Expression
        $items=if ($expression -is [Management.Automation.Language.ArrayLiteralAst]) {@($expression.Elements)} else {@($expression)}
        foreach ($item in $items) {
            if ($item -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {throw 'StepBodies may contain only literal scriptblocks.'}
            $item.ScriptBlock.Extent.Text
        }
    })
    # The driver is deliberately not evaluated. In particular, a generated exit
    # must never exit the persistent MCP process.
    $suffix=@($ast.EndBlock.Statements | Where-Object {$_.Extent.StartOffset -gt $assignment.Extent.EndOffset})
    if ($suffix.Count -ne 2 -or $suffix[0].Extent.Text -notmatch '^Invoke-AGTATestPlan\s+-StepBodies\s+\$StepBodies(?:\s+-OutputMode\s+\$OutputMode)?\s*$' -or
        $suffix[1].Extent.Text -notmatch '^exit\s+\(Get-AGTATestExitCode\)\s*$') {throw 'Keep the template Invoke-AGTATestPlan and exit driver after StepBodies; put testcase actions inside the step bodies.'}
    $prefix=$source.Substring(0,$assignment.Extent.StartOffset)
    foreach ($call in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))) {
        if ($call.Extent.StartOffset -ge $assignment.Extent.StartOffset) {continue}
        $parent=$call.Parent;$deferred=$false
        while ($parent -and $parent -ne $ast) {
            if ($parent -is [Management.Automation.Language.FunctionDefinitionAst] -or $parent -is [Management.Automation.Language.ScriptBlockExpressionAst]) {$deferred=$true;break}
            $parent=$parent.Parent
        }
        if (-not $deferred -and ($call.GetCommandName() -match '^(Invoke-(Step|Potato|Recorded|TestCleanup|EvidenceScreenshot)|Register-(OpenedProcess|CreatedExternalPath)|Complete-AGTA)' -or
            $call.Extent.Text -match '(?i)potato\.ps1')) {throw 'GUI actions and cleanup belong inside StepBodies, not plan setup.'}
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $setupHash=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($prefix))).Replace('-','')
        $scriptHash=[BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','')
    } finally {$hash.Dispose()}
    if (-not $ast.ParamBlock) {throw 'Use the generated template parameter block for a live plan.'}
    $pathLiteral=$ScriptPath.Replace("'","''")
    $rootLiteral=(Split-Path $ScriptPath).Replace("'","''")
    $executionPrefix=$prefix.Insert($ast.ParamBlock.Extent.EndOffset,"`n`$PSCommandPath='$pathLiteral'`n`$PSScriptRoot='$rootLiteral'`n")
    @{path=$ScriptPath;prefix=$executionPrefix;bodies=$bodies;setupHash=$setupHash;scriptHash=$scriptHash}
}

function Import-AGTAPlanSession {
    param([string]$RunRoot,[string]$ScriptPath,[ValidateSet('Replay','Diagnostic')] [string]$RunKind='Diagnostic')
    $manifest=[IO.File]::ReadAllText((Join-Path $RunRoot 'logs\exploration.json')) | ConvertFrom-Json
    $definition=Get-AGTAPlanDefinition $ScriptPath
    $audit=Test-AGTAGeneratedScript -ScriptPath $ScriptPath -TestCaseCsv $manifest.testCasePath -PotatoCliPath $manifest.potatoCliPath -ExplorationPath (Join-Path $RunRoot 'logs\exploration.json') -InteractionPolicy $manifest.interactionPolicy -AllowIncompleteExploration:($RunKind -eq 'Diagnostic')
    if (-not $audit.ok) {throw ('Plan preflight failed: '+($audit.issues -join '; '))}
    if ($definition.bodies.Count -ne $manifest.stepCount) {throw 'Provide one body per CSV row; leave unimplemented rows as empty scriptblocks while developing.'}
    if ($definition.scriptHash -ne (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash) {throw 'Plan changed during validation; no action dispatched.'}
    $frameworkRoot=Split-Path $PSScriptRoot
    $module=$null
    try {
        $module=New-Module -Name ('AGTAPlan_'+[guid]::NewGuid().ToString('N')) -ArgumentList $definition,$manifest,$RunRoot,$RunKind,$frameworkRoot -ScriptBlock {
            param($definition,$manifest,$run,$kind,$frameworkRoot)
            $script:AGTAPlanSessionKind=$kind
            $script:AGTAPlanDefinition=$definition
            $script:PSCommandPath=$definition.path
            $script:PSScriptRoot=Split-Path $definition.path
            $parameters=@{PotatoCliPath=$manifest.potatoCliPath;TestCaseCsv=$manifest.testCasePath;RunRoot=$run;
                FrameworkRoot=$frameworkRoot;ExplorationPath=(Join-Path $run 'logs\exploration.json');InteractionPolicy=$manifest.interactionPolicy;Transport='InProcess';OutputMode='Compact'}
            if ($manifest.policyReason) {$parameters.PolicyReason=$manifest.policyReason}
            # Dot sourcing only the validated setup keeps its variables in this
            # module. Scriptblock literals are defined here but not yet invoked.
            . ([scriptblock]::Create($definition.prefix)) @parameters | Out-Null
            $script:StepBodies=@(foreach ($body in $script:AGTAPlanDefinition.bodies) {[scriptblock]::Create($body.Substring(1,$body.Length-2))})
        }
        $context=& $module {Get-AGTAGeneratedTestContext}
        if ($context.RunRoot -ne $RunRoot -or $context.TestCaseCsv -ne $manifest.testCasePath -or $context.InteractionPolicy -ne $manifest.interactionPolicy -or $context.RunKind -ne $RunKind -or -not $context.RequireAssertions) {throw 'Plan setup changed the saved run configuration or disabled required assertions.'}
        @{module=$module;definition=$definition;context=$context;nextStepIndex=1;attempts=@();results=@();repairs=@();executedBodies=@{};
            needsReview=$false;tainted=$false;closed=$false;qualified=$false;cleanup=@();finalResult=$null;
            activeMs=0L;diagnosticResultPath=$context.ResultPath;scriptPath=$ScriptPath;runRoot=$RunRoot}
    } catch {if ($module) {Remove-Module $module -ErrorAction SilentlyContinue};throw}
}

function Update-AGTAPlanSession {
    param($Session)
    $definition=Get-AGTAPlanDefinition $Session.scriptPath
    if ($definition.scriptHash -eq $Session.definition.scriptHash) {return}
    if ($definition.setupHash -ne $Session.definition.setupHash) {throw 'Plan setup/helpers changed. Close this session before starting a new one; continuing would lose or reinterpret live variables and ownership. Step-body edits can be reloaded in place.'}
    $ctx=$Session.context
    $audit=Test-AGTAGeneratedScript -ScriptPath $Session.scriptPath -TestCaseCsv $ctx.TestCaseCsv -PotatoCliPath $ctx.PotatoCliPath -ExplorationPath $ctx.ExplorationPath -InteractionPolicy $ctx.InteractionPolicy -AllowIncompleteExploration
    if (-not $audit.ok) {throw ('Plan preflight failed: '+($audit.issues -join '; '))}
    if ($definition.bodies.Count -ne $ctx.Steps.Count -or $definition.scriptHash -ne (Get-FileHash $Session.scriptPath -Algorithm SHA256).Hash) {throw 'Plan row count or revision changed during validation.'}
    foreach ($index in $Session.executedBodies.Keys) {
        if ($Session.executedBodies[$index] -cne $definition.bodies[$index-1]) {$Session.tainted=$true}
    }
    & $Session.module {param($definition) $script:StepBodies=@(foreach ($body in $definition.bodies) {[scriptblock]::Create($body.Substring(1,$body.Length-2))});$script:AGTAPlanDefinition=$definition} $definition
    $Session.definition=$definition
}

function Save-AGTAPlanSession {
    param($Session)
    $ctx=$Session.context
    $value=[ordered]@{schemaVersion=1;runKind='Diagnostic';qualifying=$false;ok=$false;executionId=$ctx.ExecutionId;
        nextStepIndex=$Session.nextStepIndex;closed=$Session.closed;tainted=$Session.tainted;scriptPath=$Session.scriptPath;scriptHash=$Session.definition.scriptHash;
        activeExecutionMs=$Session.activeMs;attempts=@($Session.attempts);repairs=@($Session.repairs);commandLogPath=$ctx.CommandLogPath;startedAt=$ctx.StartedAt.ToString('o');updatedAt=(Get-Date).ToString('o')}
    $value | ConvertTo-Json -Depth 70 | Set-Content -LiteralPath $Session.diagnosticResultPath -Encoding UTF8
}

function Invoke-AGTAPlanStep {
    param($Session,[int]$StepIndex=0)
    if ($Session.closed) {throw 'Session is closed.'}
    if ($Session.needsReview) {throw 'Inspect agta_replay Status after a failure before dispatching more input.'}
    if (-not $StepIndex) {$StepIndex=$Session.nextStepIndex}
    if ($StepIndex -ne $Session.nextStepIndex -or $StepIndex -gt $Session.context.Steps.Count) {throw 'Run the next pending step in order. Use Skip with an explicit reason only for diagnostic continuation after live repair.'}
    Update-AGTAPlanSession $Session
    $attemptNumber=@($Session.attempts | Where-Object {$_.stepIndex -eq $StepIndex -and $_.status -ne 'BYPASSED'}).Count+1
    $Session.context.AttemptId=[guid]::NewGuid().ToString('N')
    $activeWatch=[Diagnostics.Stopwatch]::StartNew()
    $result=& $Session.module {param($index) Invoke-RecordedStep -StepIndex $index -Body $script:StepBodies[$index-1]} $StepIndex
    $Session.activeMs+=$activeWatch.ElapsedMilliseconds
    $firstAttempt=$attemptNumber -eq 1
    $passed=$result.status -eq 'PASS'
    $attempt=[ordered]@{stepIndex=$StepIndex;attempt=$attemptNumber;attemptId=$Session.context.AttemptId;scriptHash=$Session.definition.scriptHash;
        status=$(if ($passed -and $firstAttempt) {'FIRST_ATTEMPT_SUCCESS'} elseif ($passed) {'RECOVERY_SUCCESS'} else {'DIAGNOSTIC_FAILURE'});
        firstAttempt=$firstAttempt;countsAsSuccessfulStep=($passed -and $firstAttempt);error=$result.error;evidence=$result.evidence;assertions=$result.assertions;commands=$result.commands}
    $Session.attempts+=,$attempt
    $Session.executedBodies[$StepIndex]=$Session.definition.bodies[$StepIndex-1]
    if ($passed) {$Session.results+=,$result;$Session.nextStepIndex++} else {$Session.tainted=$true;$Session.needsReview=$true}
    Save-AGTAPlanSession $Session
    $lastFailure=@($result.commands | Where-Object {-not $_.ok} | Select-Object -Last 1)
    $firstAction=@($result.commands | Where-Object {$_.ok -and $_.command -in @('start','focus','click','click-coordinate','type','press-key','hotkey','drag','close-window')} | Select-Object -First 1)
    $receiptIds=@($result.commands | Where-Object {$_.verification.eligible -and (-not $firstAction.Count -or $_.index -gt $firstAction[0].index)} | ForEach-Object {$_.explorationCommandId})
    [ordered]@{ok=$passed;runKind='Diagnostic';qualifying=$false;stepIndex=$StepIndex;attempt=$attemptNumber;status=$attempt.status;
        countsAsSuccessfulStep=$attempt.countsAsSuccessfulStep;nextStepIndex=$Session.nextStepIndex;error=$result.error;
        verificationCommandIds=$receiptIds;evidence=@($result.evidence | Select-Object -Last 2);evidenceCount=@($result.evidence).Count;failedCommands=$lastFailure;
        images=@($result.commands | Where-Object {$_.command -eq 'screenshot' -and $_.path} | Select-Object -Last $(if ($passed) {2} else {1}) | ForEach-Object {@{path=$_.path;region=$_.region;format=$_.format}});
        resultPath=$Session.context.ResultPath;commandLogPath=$Session.context.CommandLogPath;
        next=$(if ($passed) {'Review evidence, RecordSteps if exploring, then develop/run the next body. Close when done.'} else {'Status retains the live failure. Inspect, edit the failed body and restore its entry state with Repair; retry Step or explicitly Skip. Do not restart passed rows.'})}
}

function Invoke-AGTAPlanRepair {
    param($Session,[object[]]$Requests)
    if ($Session.closed -or $Session.needsReview) {throw 'Inspect Status before repairing a failed live session.'}
    if ($Requests.Count -lt 1 -or $Requests.Count -gt 20) {throw 'Repair accepts 1..20 sequential commands.'}
    $ctx=$Session.context;$ctx.ActiveStep=[Math]::Min($Session.nextStepIndex,$ctx.Steps.Count)
    $ctx.AttemptId=[guid]::NewGuid().ToString('N')
    $activeWatch=[Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($request in $Requests) {
            if ($request.command -isnot [string] -or $request.arguments -isnot [array]) {throw 'Repair command needs command and arguments array.'}
            if ($request.command -notin @('observe','select','read','read-pdf','windows','state','screenshot','wait-element','wait-file')) {$Session.tainted=$true}
            $result=& $Session.module {param($command,$arguments) Invoke-PotatoJson $command $arguments} $request.command $request.arguments
            $Session.repairs+=,@{stepIndex=$ctx.ActiveStep;command=$request.command;arguments=$request.arguments;ok=$result.ok;attemptId=$ctx.AttemptId}
            $success=Test-AGTAExplorationCommandSucceeded $result $request.command
            if (-not $success) {$Session.needsReview=$true}
            $data=$result.data
            if ($request.command -eq 'windows') {$data=ConvertTo-AGTACompactWindowData $data}
            [ordered]@{ok=$success;runKind='Diagnostic';qualifying=$false;command=$request.command;data=$data;error=$result.error;
                explorationCommandId=$result.explorationCommandId;verification=$result.verification}
            if (-not $success) {break}
        }
    } finally {$Session.activeMs+=$activeWatch.ElapsedMilliseconds;$ctx.ActiveStep=0;Save-AGTAPlanSession $Session}
}

function Skip-AGTAPlanStep {
    param($Session,[string]$Reason)
    if ($Session.closed -or $Session.needsReview -or [string]::IsNullOrWhiteSpace($Reason)) {throw 'Inspect Status and provide a reason for diagnostic Skip.'}
    if ($Session.nextStepIndex -gt $Session.context.Steps.Count) {throw 'No pending step to skip.'}
    $Session.tainted=$true
    $Session.attempts+=,@{stepIndex=$Session.nextStepIndex;status='BYPASSED';countsAsSuccessfulStep=$false;reason=$Reason}
    $Session.nextStepIndex++
    Save-AGTAPlanSession $Session
    @{ok=$true;runKind='Diagnostic';qualifying=$false;nextStepIndex=$Session.nextStepIndex;status='BYPASSED'}
}

function Get-AGTAPlanStatus {
    param($Session)
    $Session.needsReview=$false
    [ordered]@{ok=$true;runKind='Diagnostic';qualifying=$false;nextStepIndex=$Session.nextStepIndex;closed=$Session.closed;tainted=$Session.tainted;
        attempts=@($Session.attempts | ForEach-Object {@{stepIndex=$_.stepIndex;attempt=$_.attempt;status=$_.status;countsAsSuccessfulStep=$_.countsAsSuccessfulStep;error=$_.error}});
        commands=@(Get-AGTACommandDiagnostics -Path $Session.context.CommandLogPath -Last 3);
        resultPath=$Session.context.ResultPath;executionEvidenceRoot=$Session.context.ExecutionEvidenceRoot;
        next='Inspect retained failure evidence/command details. Restore the failed body entry state before retrying; use Repair for sequential CLI actions, Skip only for explicit diagnostic continuation.'}
}

function Close-AGTAPlanSession {
    param($Session)
    if ($Session.qualified) {
        if ($Session.definition.scriptHash -ne (Get-FileHash -LiteralPath $Session.scriptPath -Algorithm SHA256).Hash) {throw 'The qualified script revision changed. Use Verify to test the final saved revision; the previous result remains historical.'}
        return $Session.finalResult
    }
    $updateError=$null
    try {Update-AGTAPlanSession $Session} catch {$updateError=$_.Exception.Message;$Session.tainted=$true}
    $activeWatch=[Diagnostics.Stopwatch]::StartNew()
    $cleanup=if ($Session.closed) {@($Session.cleanup)} else {@(& $Session.module {Invoke-TestCleanup})}
    if (-not $Session.closed) {$Session.activeMs+=$activeWatch.ElapsedMilliseconds}
    $Session.cleanup=$cleanup
    $Session.closed=$true
    Save-AGTAPlanSession $Session
    $clean=(-not $Session.tainted -and $Session.results.Count -eq $Session.context.Steps.Count -and @($cleanup | Where-Object {-not $_.ok}).Count -eq 0)
    if ($clean) {
        $ctx=$Session.context
        $manifest=[IO.File]::ReadAllText($ctx.ExplorationPath) | ConvertFrom-Json
        if (-not $manifest.completed) {
            # Recording still requires agent review through RecordSteps. Close
            # does not invent verification or silently mark unreviewed rows.
            Complete-AGTAExploration $ctx.RunRoot $ctx.TestCaseCsv $ctx.InteractionPolicy | Out-Null
        }
        $audit=Test-AGTAGeneratedScript -ScriptPath $Session.scriptPath -TestCaseCsv $ctx.TestCaseCsv -PotatoCliPath $ctx.PotatoCliPath -ExplorationPath $ctx.ExplorationPath -InteractionPolicy $ctx.InteractionPolicy
        if (-not $audit.ok) {throw ('Final qualification preflight failed: '+($audit.issues -join '; '))}
        if ((Get-FileHash $Session.scriptPath -Algorithm SHA256).Hash -ne $Session.definition.scriptHash) {throw 'Plan changed during final qualification.'}
        $ctx.RunKind='Replay';$ctx.ResultPath=Join-Path $ctx.ResultsRoot 'result.json';$ctx.ScriptAudit=$audit
        $ctx.Timing.activeExecutionMs=$Session.activeMs
        $ctx.Timing.pausedMs=[Math]::Max(0,[long]((Get-Date)-$ctx.StartedAt).TotalMilliseconds-$Session.activeMs)
        $Session.finalResult=& $Session.module {param($results,$cleanup,$hash) Complete-AGTAGeneratedTest -StepResults $results -Cleanup $cleanup -ExtraArtifacts @{scriptHash=$hash;executionMode='IncrementalFirstAttempt'}} $Session.results $cleanup $Session.definition.scriptHash
        $Session.qualified=$true
        $Session.finalResult
    } else {
        @{ok=$true;runKind='Diagnostic';qualifying=$false;cleanupOk=(@($cleanup | Where-Object {-not $_.ok}).Count -eq 0);
            resultPath=$Session.diagnosticResultPath;updateError=$updateError;next='Recovery work is preserved. Verify the final revision from the beginning for a qualifying full result.'}
    }
}

function Get-AGTACommandDiagnostics {
    param([string]$Path,[ValidateRange(1,20)] [int]$Last=3,[int]$StepIndex=0)
    if (-not [IO.File]::Exists($Path)) {return}
    $queue=New-Object 'Collections.Generic.Queue[object]'
    $reader=[IO.File]::OpenText($Path)
    try {
        while ($null -ne ($line=$reader.ReadLine())) {
            $entry=$line | ConvertFrom-Json
            if ($StepIndex -and $entry.stepIndex -ne $StepIndex) {continue}
            $queue.Enqueue($entry);if ($queue.Count -gt $Last) {[void]$queue.Dequeue()}
        }
    } finally {$reader.Dispose()}
    foreach ($entry in $queue) {
        $result=if ($entry.parsed) {$entry.parsed} else {$entry.result}
        $data=[ordered]@{}
        foreach ($name in @('action','target','inputFocus','verification','path','region','visualWait','conditionMet','text','content','count','root','search','foregroundSelector','focusedElement','keyboardFocus')) {
            if ($null -ne $result.data.$name) {$data[$name]=$result.data.$name}
        }
        if ($result.data.elements) {$data.elements=@($result.data.elements | Select-Object -First 20);$data.elementsOmitted=[Math]::Max(0,$result.data.elements.Count-20)}
        [ordered]@{index=$entry.index;id=$entry.id;stepIndex=$entry.stepIndex;command=$entry.command;arguments=$entry.arguments;
            ok=$result.ok;outcome=$result.outcome;durationMs=$result.durationMs;error=$result.error;data=$data;fullLogPath=$Path}
    }
}
