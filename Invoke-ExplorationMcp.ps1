[CmdletBinding()]
param([switch]$EnableShortcutPolicy)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$env:AGTA_PROVIDER_ISOLATION='1'
$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+$env:PSModulePath
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$entry=Join-Path $PSScriptRoot 'Invoke-Exploration.ps1'
. (Join-Path $PSScriptRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $PSScriptRoot 'Framework\ReplaySession.ps1')
$ready=$false
$negotiated=$false
$reviewRequired=@{}
$planSessions=@{}
$availablePolicies=@('GuiNavigation','VisibleControls')
if ($EnableShortcutPolicy) {$availablePolicies+=,'AllowShortcuts'}
$tools=@(
    @{name='agta_explore';description='Explore first: Begin, Batch observed GUI actions, review RecordSteps, clean owned windows, Complete. No saved script is needed for exploration. Then generate from tested receipts and Replay Verify. IN_PROGRESS retains the session: continue Step then Close. Failure retains state for Status/Repair/Step/Skip. ProviderTimeout has unknown action outcome; inspect before further input. Use visible controls; reasons cannot authorize shortcuts.';
        inputSchema=@{type='object';required=@('action','runRoot');additionalProperties=$false;properties=@{
            action=@{type='string';enum=@('Begin','Batch','RecordSteps','Status','Complete','Replay')};runRoot=@{type='string'};
            workflowMode=@{type='string';enum=@('RecordedBatch','Live');description='Begin only. RecordedBatch is default: explore before writing code. Live explicitly opts into saved-body development; Batch is read-only in Live.'};
            replayAction=@{type='string';enum=@('Start','Step','Repair','Skip','Status','Close','Verify');description='Required with action Replay; identical to agta_replay action.'};
            scriptPath=@{type='string'};stepIndex=@{type='integer';minimum=1;description='Replay Repair: required for GUI input; actual CSV row for receipts. Does not advance the pending row.'};reason=@{type='string'};
            testCaseCsv=@{type='string'};potatoCliPath=@{type='string'};
            interactionPolicy=@{type='string';enum=$availablePolicies};policyReason=@{type='string';description='Records existing user/testcase authorization, never an agent justification. Does not enable shortcut capability.'};
            requests=@{type='array';items=@{type='object'};description='Batch: {stepIndex,command,arguments:[],key?}. Identity/evidence argument values may use {resultRef:"earlierKey",path:"data.checkpointId"} to bind a previous result in this batch. RecordSteps: {stepIndex,route,observedResult,verificationCommandIds:[]}. Structured *Json values are supported.'};
            includeImages=@{type='boolean';description='Batch screenshots return their original PNG/JPEG pixels inline by default (last two, <=10 MiB each), alongside receipt/physical region. Inspect these directly without another file-view call. Set false for text-only receipts.'}
        }}}
    @{name='agta_validate';description='Optional read-only standalone replay preflight using saved CSV/policy/manifest; completed exploration required. agta_replay Step/Verify and standalone scripts validate internally, so do not duplicate this check before each execution. Parses source without executing it; never substitutes for a passed run.';
        inputSchema=@{type='object';required=@('runRoot','scriptPath');additionalProperties=$false;properties=@{
            runRoot=@{type='string';description='Absolute existing exploration runRoot.'};scriptPath=@{type='string';description='Absolute generated replay path.'}
        }}}
    @{name='agta_help';description='Read the authoring guide/template once, targeted CLI/runtime signatures, or restore a tested replay row after compaction. Use topic authoring first; replay takes runRoot and optional stepIndex. Complete already returns the compact route inline; do not dump verbose discovery history or runtime modules.';
        inputSchema=@{type='object';required=@('topic');additionalProperties=$false;properties=@{
            topic=@{type='string';enum=@('authoring','cli','runtime','replay')};testCaseCsv=@{type='string';description='Authoring context can include the supplied CSV alongside the guide/template.'};names=@{type='array';minItems=1;maxItems=20;items=@{type='string'}};
            runRoot=@{type='string';description='Replay topic: completed run whose tested route reference should be restored after context compaction.'};stepIndex=@{type='integer';minimum=1;description='Replay topic: return only this CSV row; omit for all rows.'};
            detail=@{type='string';enum=@('signatures','full');description='Targeted help defaults to compact signatures; request full only for unresolved behavior.'}
        }}}
    @{name='agta_replay';description='After exploration, Verify runs the saved script once. IN_PROGRESS retains the session: continue Step from nextStepIndex, then Close. Failure retains state: Status, edit bodies/helpers, Repair with actual CSV stepIndex, then Step after restoring row entry state or Skip a manually finished row and continue. Never restart successful rows for helper/selector edits. First-attempt full success qualifies without repetition. Repaired sessions need one final clean Verify. ProviderTimeout has unknown outcome; inspect before input.';
        inputSchema=@{type='object';required=@('action','runRoot');additionalProperties=$false;properties=@{
            action=@{type='string';enum=@('Start','Step','Repair','Skip','Status','Close','Verify')};runRoot=@{type='string'};
            scriptPath=@{type='string';description='Absolute template-based script path for Start/Verify; Step reloads saved bodies and helper functions without resetting state.'};
            stepIndex=@{type='integer';minimum=1;description='Step: next pending row. Repair: required for GUI input, identifies the actual CSV row for receipts; does not advance the plan.'};reason=@{type='string';description='Skip: required. Close: explicit abandonment reason only when recovery cannot continue or the task is cancelled. Normal Close follows the last row; helpers/selectors reload live.'};
            requests=@{type='array';minItems=1;maxItems=20;items=@{type='object';required=@('command','arguments');additionalProperties=$false;properties=@{command=@{type='string'};arguments=@{type='array'}}}};
            includeImages=@{type='boolean';description='Return up to two retained screenshot evidence files inline; default true.'}
        }}}
    @{name='agta_inspect';description='Read bounded structured command diagnostics, or source image to measure retained image pixels against a reference without rerunning GUI input. Returns metrics/display orientation, never a qualifying PASS. Full command records stay on disk.';
        inputSchema=@{type='object';required=@('runRoot');additionalProperties=$false;properties=@{
            runRoot=@{type='string'};source=@{type='string';enum=@('exploration','replay','image')};last=@{type='integer';minimum=1;maximum=20};stepIndex=@{type='integer';minimum=1};
            imagePath=@{type='string'};referencePath=@{type='string'};referenceRotation=@{type='integer';enum=@(0,90,180,270)};
            region=@{type='object';description='Optional observed rectangle x,y,width,height in decoded display pixels of imagePath. No region means whole image.'}
        }}}
)
function Invoke-McpTool($Name,$Arguments) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    if (-not $Arguments -or $Arguments -is [array] -or $Arguments -isnot [pscustomobject]) {throw 'Tool arguments must be an object.'}
    if ($Name -eq 'agta_explore' -and $Arguments.action -ceq 'Replay') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('action','replayAction','runRoot','scriptPath','stepIndex','reason','requests','includeImages')) {throw "Unknown live replay argument: $property"}}
        $mapped=@{action=$Arguments.replayAction;runRoot=$Arguments.runRoot}
        foreach ($key in @('scriptPath','stepIndex','reason','requests','includeImages')) {if ($Arguments.PSObject.Properties.Name -contains $key) {$mapped[$key]=$Arguments.$key}}
        return Invoke-McpTool 'agta_replay' ([pscustomobject]$mapped)
    }
    $global:LASTEXITCODE=0
    if ($Name -eq 'agta_explore') {
        $allowed=@('action','runRoot','testCaseCsv','potatoCliPath','interactionPolicy','policyReason','requests','includeImages','workflowMode')
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin $allowed) {throw "Unknown exploration argument: $property"}}
        if ($Arguments.PSObject.Properties.Name -contains 'includeImages' -and $Arguments.includeImages -isnot [bool]) {throw 'includeImages must be Boolean.'}
        if ($Arguments.action -cnotin @('Begin','Batch','RecordSteps','Status','Complete') -or -not $Arguments.runRoot -or -not [IO.Path]::IsPathRooted($Arguments.runRoot)) {throw 'Use a supported action and an absolute runRoot.'}
        $runKey=[IO.Path]::GetFullPath($Arguments.runRoot)
        if ($Arguments.PSObject.Properties.Name -contains 'workflowMode' -and ($Arguments.action -ne 'Begin' -or $Arguments.workflowMode -cnotin @('Live','RecordedBatch'))) {throw 'workflowMode is Begin-only: Live or RecordedBatch.'}
        $manifestPath=Join-Path $runKey 'logs\exploration.json'
        $savedManifest=if ([IO.File]::Exists($manifestPath)) {[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json} else {$null}
        if ($Arguments.action -eq 'Batch' -and $savedManifest.workflowMode -eq 'Live' -and
            @($Arguments.requests | Where-Object {-not (Test-AGTAReadOnlyCommand $_.command)}).Count) {
            throw 'Live authoring requires testing the saved body. Save the template, then call agta_explore action Replay, replayAction Start with scriptPath, and replayAction Step. Use Replay Repair for live recovery; Batch is read-only discovery. Do not restart the full script.'
        }
        if ($Arguments.action -eq 'Batch' -and @($planSessions.Values | Where-Object {-not $_.closed}).Count -and
            @($Arguments.requests | Where-Object {-not (Test-AGTAReadOnlyCommand $_.command)}).Count) {
            throw 'A live plan owns this desktop route. Use agta_replay Repair for GUI input so repairs and ownership are recorded; agta_explore remains available for read-only discovery and RecordSteps.'
        }
        if (-not $EnableShortcutPolicy) {
            $savedPolicy=$null
            $manifestPath=Join-Path $runKey 'logs\exploration.json'
            if ([IO.File]::Exists($manifestPath)) {$savedPolicy=([IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json).interactionPolicy}
            if ($Arguments.interactionPolicy -eq 'AllowShortcuts' -or ($Arguments.action -in @('Batch','RecordSteps','Complete') -and $savedPolicy -eq 'AllowShortcuts')) {
                throw 'Shortcut authorization is disabled in this MCP server. A policyReason cannot enable it. Use GuiNavigation/VisibleControls and observed menu/button routes. Only the operator may enable shortcut capability at server startup after an explicit user request.'
            }
        }
        if ($Arguments.action -eq 'Batch' -and $reviewRequired[$runKey]) {throw 'The previous batch failed. Call Status and inspect the failed receipt/actual GUI before submitting a recovery batch.'}
        $parameters=@{Action=$Arguments.action;RunRoot=$Arguments.runRoot;Transport='InProcess';OutputMode='Compact'}
        foreach ($key in @('testCaseCsv','potatoCliPath','interactionPolicy','policyReason')) {if ($Arguments.$key) {$parameters[$key]=$Arguments.$key}}
        if ($Arguments.action -in @('Batch','RecordSteps')) {
            if ($Arguments.requests -isnot [array] -or -not $Arguments.requests.Count) {throw 'Batch/RecordSteps requires a nonempty requests array.'}
            $parameters.RequestsJson=ConvertTo-Json -InputObject $Arguments.requests -Depth 50 -Compress
        } elseif ($Arguments.PSObject.Properties.Name -contains 'requests') {throw 'Only Batch/RecordSteps accepts requests.'}
        $responses=@(& $entry @parameters)
        if ($Arguments.action -eq 'Batch' -and $LASTEXITCODE -ne 0) {$reviewRequired[$runKey]=$true}
        if ($Arguments.action -eq 'Status' -and $LASTEXITCODE -eq 0) {$reviewRequired.Remove($runKey)}
        if ($Arguments.action -eq 'Begin' -and $LASTEXITCODE -eq 0) {
            $mode=if ($Arguments.workflowMode) {$Arguments.workflowMode} else {'RecordedBatch'}
            $savedManifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            $savedManifest | Add-Member -NotePropertyName workflowMode -NotePropertyValue $mode -Force
            $savedManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            $begin=$responses[-1] | ConvertFrom-Json
            $begin | Add-Member -NotePropertyName stepCount -NotePropertyValue @($begin.steps).Count -Force
            $begin.PSObject.Properties.Remove('steps')
            $begin | Add-Member -NotePropertyName workflowMode -NotePropertyValue $mode -Force
            $begin | Add-Member -NotePropertyName replayAvailable -NotePropertyValue $true -Force
            $begin.next=if ($mode -eq 'Live') {'Explicit Live mode: save bodies incrementally and use Replay Start/Step. Batch is read-only. Bodies/helpers reload without resetting state; initializers require Close/Start. Review RecordSteps and Close to qualify clean first attempts.'} else {'Explore now with Batch; no script is required. Use observed controls and real row indices, review RecordSteps, clean owned windows, Complete. Only then generate from tested receipts and call Replay Verify once. Failed Verify retains state for recovery.'}
            if ($mode -eq 'Live') {$begin | Add-Member nextCall @{tool='agta_explore';arguments=@{action='Replay';replayAction='Start';runRoot=$runKey;scriptPath='<absolute saved template path>'}} -Force}
            $begin.workflow.nextAction=$begin.next
            $responses[-1]=$begin | ConvertTo-Json -Depth 80 -Compress
        }
    } elseif ($Name -eq 'agta_validate') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('runRoot','scriptPath')) {throw "Unknown validation argument: $property"}}
        if (-not $Arguments.runRoot -or -not $Arguments.scriptPath -or -not [IO.Path]::IsPathRooted($Arguments.runRoot) -or -not [IO.Path]::IsPathRooted($Arguments.scriptPath)) {throw 'Validation requires absolute runRoot and scriptPath.'}
        $manifestPath=Join-Path $Arguments.runRoot 'logs\exploration.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $scriptHash=if (Test-Path -LiteralPath $Arguments.scriptPath -PathType Leaf) {(Get-FileHash -LiteralPath $Arguments.scriptPath -Algorithm SHA256).Hash} else {$null}
        $audit=Test-AGTAGeneratedScript -ScriptPath $Arguments.scriptPath -TestCaseCsv $manifest.testCasePath -PotatoCliPath $manifest.potatoCliPath -ExplorationPath $manifestPath -InteractionPolicy $manifest.interactionPolicy
        $currentHash=if (Test-Path -LiteralPath $Arguments.scriptPath -PathType Leaf) {(Get-FileHash -LiteralPath $Arguments.scriptPath -Algorithm SHA256).Hash} else {$null}
        if ($scriptHash -ne $currentHash) {$audit.ok=$false;$audit.issues+=,'Script changed during validation. Validate the saved revision again before replay.'}
        $result=[ordered]@{ok=$audit.ok;stage='replay_preflight';replayExecuted=$false;taskComplete=$false;issues=$audit.issues;checkedCommands=$audit.checkedCommands;
            scriptPath=$Arguments.scriptPath;scriptHash=$scriptHash;
            nextAction=$(if ($audit.ok) {'Use the saved revision with agta_replay Step/Verify, or run the standalone script. Execution validates internally; static validation alone is not task completion.'} else {'Correct the issues. Incomplete exploration may continue through live diagnostic Step development; full qualifying replay still requires all reviewed rows. Do not deliver a partial script.'})}
        if (-not $audit.ok) {$global:LASTEXITCODE=1}
        $responses=@(($result | ConvertTo-Json -Depth 8 -Compress))
    } elseif ($Name -eq 'agta_replay') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('action','runRoot','scriptPath','stepIndex','reason','requests','includeImages')) {throw "Unknown replay argument: $property"}}
        if (-not $Arguments.runRoot -or -not [IO.Path]::IsPathRooted($Arguments.runRoot)) {throw 'Replay requires an absolute runRoot.'}
        if ($Arguments.includeImages -and $Arguments.includeImages -isnot [bool]) {throw 'includeImages must be Boolean.'}
        $runKey=[IO.Path]::GetFullPath($Arguments.runRoot)
        $session=$planSessions[$runKey]
        $manifestPath=Join-Path $runKey 'logs\exploration.json'
        $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.interactionPolicy -eq 'AllowShortcuts' -and -not $EnableShortcutPolicy) {throw 'Shortcut authorization is disabled in this MCP server.'}
        switch -CaseSensitive ($Arguments.action) {
            'Start' {
                if (@($planSessions.Values | Where-Object {-not $_.closed}).Count) {throw 'Close the existing live plan before starting another desktop session.'}
                if ($manifest.workflowMode -eq 'RecordedBatch' -and -not (Test-AGTAExploration -Path $manifestPath -TestCaseCsv $manifest.testCasePath -InteractionPolicy $manifest.interactionPolicy).ok) {throw 'Explore first with Batch, review RecordSteps, clean owned windows and Complete before Replay Start/Verify. Do not write guessed selectors before observing the UI.'}
                if (-not $Arguments.scriptPath -or -not [IO.Path]::IsPathRooted($Arguments.scriptPath)) {throw 'Start needs absolute scriptPath.'}
                if ($session) {Remove-Module $session.module -ErrorAction SilentlyContinue}
                $session=Import-AGTAPlanSession $runKey $Arguments.scriptPath
                $planSessions[$runKey]=$session
                Save-AGTAPlanSession $session
                $value=@{ok=$true;runKind='Diagnostic';qualifying=$false;nextStepIndex=1;executionEvidenceRoot=$session.context.ExecutionEvidenceRoot;resultPath=$session.context.ResultPath;next='Run the next saved body with Step. Variables, paths and ownership persist; body/helper edits reload in place. RecordSteps only when still exploring.'}
            }
            'Step' {if (-not $session) {throw 'Start the live plan first.'};$value=Invoke-AGTAPlanStep $session -StepIndex $Arguments.stepIndex}
            'Repair' {if (-not $session) {throw 'Start the live plan first.'};$value=@(Invoke-AGTAPlanRepair $session $Arguments.requests -StepIndex $Arguments.stepIndex)}
            'Skip' {if (-not $session) {throw 'Start the live plan first.'};$value=Skip-AGTAPlanStep $session $Arguments.reason}
            'Status' {if (-not $session) {throw 'Start the live plan first.'};$value=Get-AGTAPlanStatus $session}
            'Close' {if (-not $session) {throw 'Start the live plan first.'};$value=Close-AGTAPlanSession $session -Reason $Arguments.reason}
            'Verify' {
                if (@($planSessions.Values | Where-Object {-not $_.closed}).Count) {throw 'Close the live desktop session first so ownership cleanup precedes any full replay.'}
                if ($session -and $session.qualified -and $session.definition.scriptHash -eq (Get-FileHash $session.scriptPath -Algorithm SHA256).Hash -and
                    (-not $Arguments.scriptPath -or $Arguments.scriptPath -eq $session.scriptPath)) {$value=$session.finalResult;break}
                $path=if ($Arguments.scriptPath) {$Arguments.scriptPath} elseif ($session) {$session.scriptPath} else {$null}
                if (-not $path -or -not [IO.Path]::IsPathRooted($path)) {throw 'Verify needs an absolute scriptPath.'}
                if ($session -and -not (Test-AGTAExploration -Path $session.context.ExplorationPath -TestCaseCsv $manifest.testCasePath -InteractionPolicy $manifest.interactionPolicy).ok) {
                    Complete-AGTAExploration $runKey $manifest.testCasePath $manifest.interactionPolicy | Out-Null
                }
                $explorationAudit=Test-AGTAExploration -Path (Join-Path $runKey 'logs\exploration.json') -TestCaseCsv $manifest.testCasePath -InteractionPolicy $manifest.interactionPolicy
                if (-not $explorationAudit.ok) {throw ('Verify requires reviewed complete exploration. Use Replay Start/Step to develop missing rows: '+($explorationAudit.issues -join '; '))}
                if ($session) {Remove-Module $session.module -ErrorAction SilentlyContinue}
                $verification=Import-AGTAPlanSession $runKey $path
                $planSessions[$runKey]=$verification
                $value=Invoke-AGTAPlanVerification $verification
            }
            default {throw 'Unsupported replay action.'}
        }
        $responses=@($value | ForEach-Object {if ($_ -is [string]) {$_} else {$_ | ConvertTo-Json -Depth 70 -Compress}})
        if (@($responses | ForEach-Object {$_ | ConvertFrom-Json} | Where-Object {$_.ok -eq $false}).Count) {$global:LASTEXITCODE=1}
    } elseif ($Name -eq 'agta_inspect') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('runRoot','source','last','stepIndex','imagePath','referencePath','referenceRotation','region')) {throw "Unknown inspection argument: $property"}}
        if (-not $Arguments.runRoot -or -not [IO.Path]::IsPathRooted($Arguments.runRoot)) {throw 'Inspection needs an absolute runRoot.'}
        $source=if ($Arguments.source) {$Arguments.source} else {'replay'}
        if ($source -notin @('exploration','replay','image')) {throw 'Inspection source must be exploration, replay or image.'}
        if ($source -eq 'image') {
            if ($Arguments.PSObject.Properties.Name -contains 'last' -or $Arguments.PSObject.Properties.Name -contains 'stepIndex') {throw 'Image inspection does not take command-history filters.'}
            foreach ($file in @($Arguments.imagePath,$Arguments.referencePath)) {if (-not $file -or -not [IO.Path]::IsPathRooted($file)) {throw 'Image inspection needs absolute imagePath and referencePath.'}}
            $rotation=if ($null -ne $Arguments.referenceRotation) {$Arguments.referenceRotation} else {0}
            $metrics=Measure-ImageRegionMatch -Path $Arguments.imagePath -ReferencePath $Arguments.referencePath -Region $Arguments.region -ReferenceRotation $rotation
            $value=@{ok=$true;metrics=$metrics;qualifying=$false;note='Read-only pixel metrics. Review against the required expectation; retain content assertions in replay. No GUI input or file writes.'}
        } else {
            if (@('imagePath','referencePath','referenceRotation','region') | Where-Object {$_ -in $Arguments.PSObject.Properties.Name}) {throw 'Image arguments require source image.'}
            $path=if ($source -eq 'exploration') {Join-Path $Arguments.runRoot 'logs\exploration-commands.jsonl'} else {
                $file=Get-ChildItem -LiteralPath (Join-Path $Arguments.runRoot 'logs') -Filter 'potato-commands-*.jsonl' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                if ($file) {$file.FullName} else {$null}
            }
            $last=if ($null -ne $Arguments.last) {[int]$Arguments.last} else {3}
            $value=@{ok=$true;commands=@(Get-AGTACommandDiagnostics $path -Last $last -StepIndex $Arguments.stepIndex);fullLogPath=$path}
            $active=Join-Path $Arguments.runRoot 'logs\active-provider-command.json'
            if (Test-Path -LiteralPath $active) {$value.providerProgress=[IO.File]::ReadAllText($active) | ConvertFrom-Json}
        }
        $responses=@(($value | ConvertTo-Json -Depth 40 -Compress))
    } elseif ($Name -eq 'agta_help') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('topic','names','testCaseCsv','detail','runRoot','stepIndex')) {throw "Unknown help argument: $property"}}
        if ($Arguments.detail -and $Arguments.detail -notin @('signatures','full')) {throw 'Help detail must be signatures or full.'}
        if ($Arguments.topic -eq 'authoring') {
            # Get-Content strings carry provider metadata in PS5. ConvertTo-Json
            # can serialize their PSDrive/.NET object graph instead of plain text.
            $context=@{guide=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'docs\AUTHORING.md'));
                template=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\GeneratedScript.Template.ps1'));
                interactionPolicies=$availablePolicies;shortcutPolicyEnabled=[bool]$EnableShortcutPolicy}
            if ($Arguments.testCaseCsv) {$context.steps=@(Import-Csv -LiteralPath $Arguments.testCaseCsv)}
            $responses=@(($context | ConvertTo-Json -Depth 5 -Compress))
        } elseif ($Arguments.topic -eq 'replay') {
            if (-not $Arguments.runRoot -or -not [IO.Path]::IsPathRooted($Arguments.runRoot)) {throw 'Replay help requires an absolute completed runRoot.'}
            $path=Join-Path $Arguments.runRoot 'logs\replay-reference.json'
            $reference=[IO.File]::ReadAllText($path) | ConvertFrom-Json
            if ($Arguments.stepIndex) {
                $reference.steps=@($reference.steps | Where-Object {$_.stepIndex -eq $Arguments.stepIndex})
                if (-not $reference.steps.Count) {throw 'Replay reference does not contain that CSV row.'}
            }
            $responses=@(($reference | ConvertTo-Json -Depth 30 -Compress))
        } elseif ($Arguments.topic -in @('cli','runtime')) {
            if ($Arguments.names -isnot [array] -or $Arguments.names.Count -lt 1 -or $Arguments.names.Count -gt 20 -or @($Arguments.names | Where-Object {$_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_ -match ','}).Count) {throw 'Targeted help requires 1..20 nonempty names without commas.'}
            $names=$Arguments.names -join ','
            if ($Arguments.topic -eq 'cli') {$responses=@(& (Join-Path (Split-Path $PSScriptRoot) 'potato-cli\potato.ps1') help -Topics $names -Format $(if ($Arguments.detail -eq 'full') {'Full'} else {'Compact'}))}
            else {
                $responses=@(& (Join-Path $PSScriptRoot 'Get-RuntimeHelp.ps1') -Names $names)
                if ($Arguments.detail -ne 'full') {
                    $entries=@($responses | ForEach-Object {$_ | ConvertFrom-Json} | ForEach-Object {@{name=$_.name;syntax=$_.syntax;parameterConstraints=$_.parameterConstraints}})
                    $responses=@((ConvertTo-Json -InputObject $entries -Depth 8 -Compress))
                }
            }
        } else {throw 'Help topic must be authoring, cli, runtime or replay.'}
    } else {throw "Unknown tool: $Name"}
    $failed=$LASTEXITCODE -ne 0
    if (-not $responses.Count) {throw 'Entrypoint returned no response; inspect Status/GUI before retrying.'}
    $last=$responses.Count-1
    $final=$responses[$last] | ConvertFrom-Json
    if ($final -is [pscustomobject]) {
        if ($Name -eq 'agta_explore' -and $Arguments.action -eq 'Batch' -and $failed -and $final.workflow) {
            $final.workflow.nextAction='Call agta_explore with action Status on this runRoot, inspect the failed receipt and actual GUI, then submit one observed recovery Batch. Do not repeat uncertain input or skip unfinished rows.'
        }
        $responses[$last]=$final | ConvertTo-Json -Depth 80 -Compress
    }
    $content=@(@{type='text';text=$responses -join "`n"})
    if (($Name -eq 'agta_explore' -and $Arguments.action -eq 'Batch' -or $Name -eq 'agta_replay') -and $Arguments.includeImages -ne $false) {
        $screens=@($responses | ForEach-Object {$_ | ConvertFrom-Json} | Where-Object {$_.command -eq 'screenshot' -and $_.ok} | Select-Object -Last 2)
        if ($Name -eq 'agta_replay' -and $Arguments.action -in @('Step','Verify')) {
            $screens+=@($final.images | ForEach-Object {
                @{explorationCommandId='step-evidence';data=@{path=$_.path;format=$_.format;region=$_.region}}
            })
        }
        foreach ($screen in $screens) {
            try {
                $path=[string]$screen.data.path
                $file=Get-Item -LiteralPath $path -ErrorAction Stop
                if ($file.Length -gt 10485760) {throw 'Screenshot exceeds the inline 10 MiB bound; inspect its saved file.'}
                $mime=switch ([string]$screen.data.format) {'PNG' {'image/png'};'JPEG' {'image/jpeg'};'JPG' {'image/jpeg'};default {throw 'Inline screenshots support PNG/JPEG; inspect the saved file.'}}
                $bytes=[IO.File]::ReadAllBytes($file.FullName)
                if ($bytes.Length -gt 10485760) {throw 'Screenshot grew beyond the inline bound.'}
                $content+=@{type='text';text=('Screenshot receipt '+$screen.explorationCommandId+'; physical region '+($screen.data.region | ConvertTo-Json -Compress)+'. Original pixels; use region origin for coordinates.')}
                $content+=@{type='image';mimeType=$mime;data=[Convert]::ToBase64String($bytes)}
            } catch {$content+=@{type='text';text=('Inline screenshot unavailable: '+$_.Exception.Message+' Receipt/file remain valid.')}}
        }
    }
    if ($final -is [pscustomobject]) {
        $final | Add-Member -NotePropertyName mcpTiming -NotePropertyValue @{requestMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,2)} -Force
        $responses[$last]=$final | ConvertTo-Json -Depth 80 -Compress
        $content[0].text=$responses -join "`n"
    }
    @{content=$content;isError=$failed}
}
# MCP stdio: exactly one JSON-RPC response per input line; no banners or logs on
# stdout. CLI work stays in this process and uses the authoritative entrypoint.
while ($null -ne ($line=[Console]::ReadLine())) {
    $request=$null;$reply=$null
    try {$request=$line.TrimStart([char]0xFEFF) | ConvertFrom-Json}
    catch {$reply=@{jsonrpc='2.0';id=$null;error=@{code=-32700;message='Invalid JSON.'}}}
    if (-not $reply) {
        $hasId=$request -and $request.PSObject.Properties.Name -contains 'id'
        if (-not $request -or $request -is [array] -or $request.jsonrpc -cne '2.0' -or $request.method -isnot [string]) {
            $reply=@{jsonrpc='2.0';id=$null;error=@{code=-32600;message='Invalid JSON-RPC request.'}}
        } elseif (-not $hasId) {
            if ($request.method -eq 'notifications/initialized' -and $negotiated) {$ready=$true}
            continue
        } else {
            $reply=@{jsonrpc='2.0';id=$request.id}
            try {
                switch ($request.method) {
                    'initialize' {
                        if ($request.params.protocolVersion -isnot [string] -or -not $request.params.protocolVersion) {throw 'Initialize requires protocolVersion.'}
                        $version=if ($request.params.protocolVersion -in @('2024-11-05','2025-03-26','2025-06-18')) {$request.params.protocolVersion} else {'2025-06-18'}
                        $reply.result=@{protocolVersion=$version;capabilities=@{tools=@{listChanged=$false}};serverInfo=@{name='agta-exploration';version='1.6.0'}}
                        $negotiated=$true;$ready=$false
                    }
                    'ping' {$reply.result=@{}}
                    'tools/list' {if (-not $ready) {throw 'Initialize the MCP session first.'};$reply.result=@{tools=$tools}}
                    'tools/call' {
                        if (-not $ready) {throw 'Initialize the MCP session first.'}
                        if ($request.params.name -cnotin @('agta_explore','agta_help','agta_validate','agta_replay','agta_inspect')) {$reply.error=@{code=-32602;message='Unknown tool.'};break}
                        try {$reply.result=Invoke-McpTool $request.params.name $request.params.arguments}
                        catch {
                            $failure=@{ok=$false;error=$_.Exception.Message;next='Inspect Status/actual GUI before retrying an uncertain dispatch.'}
                            $sourceLine=([string]$_.InvocationInfo.Line).Trim()
                            if ($sourceLine.Length -gt 240) {$sourceLine=$sourceLine.Substring(0,240)+'...'}
                            $savedPath=$request.params.arguments.scriptPath
                            if ($_.CategoryInfo.Category -ne 'OperationStopped' -or ($savedPath -and $_.ScriptStackTrace -match [regex]::Escape($savedPath))) {
                                $failure.location=@{file=$_.InvocationInfo.ScriptName;line=$_.InvocationInfo.ScriptLineNumber;command=$sourceLine;stack=@($_.ScriptStackTrace -split "`r?`n" | Select-Object -First 3)}
                            }
                            $reply.result=@{content=@(@{type='text';text=($failure | ConvertTo-Json -Depth 8 -Compress)});isError=$true}
                        }
                    }
                    default {$reply.error=@{code=-32601;message='Method not found.'}}
                }
            } catch {$reply.error=@{code=-32602;message=$_.Exception.Message}}
        }
    }
    [Console]::WriteLine((ConvertTo-Json -InputObject $reply -Depth 100 -Compress))
}
