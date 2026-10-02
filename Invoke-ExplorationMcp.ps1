[CmdletBinding()]
param([switch]$EnableShortcutPolicy)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
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
    @{name='agta_explore';description='Begin once, then develop the actual saved StepBodies live using action Replay with replayAction Start/Step/Status/Repair/Close/Verify, or agta_replay. Live is the default; Batch is read-only discovery, RecordSteps reviews real verification receipts. GUI input belongs in tested saved bodies or recorded live Repair. Do not translate a separate walkthrough or repeatedly run scripts through the shell. RecordedBatch is an explicit legacy mode. Use visible controls; agent reasons cannot authorize shortcuts.';
        inputSchema=@{type='object';required=@('action','runRoot');additionalProperties=$false;properties=@{
            action=@{type='string';enum=@('Begin','Batch','RecordSteps','Status','Complete','Replay')};runRoot=@{type='string'};
            workflowMode=@{type='string';enum=@('Live','RecordedBatch');description='Begin only. Live is default. RecordedBatch explicitly selects the old separate walkthrough when required.'};
            replayAction=@{type='string';enum=@('Start','Step','Repair','Skip','Status','Close','Verify');description='Required with action Replay; identical to agta_replay action.'};
            scriptPath=@{type='string'};stepIndex=@{type='integer';minimum=1};reason=@{type='string'};
            testCaseCsv=@{type='string'};potatoCliPath=@{type='string'};
            interactionPolicy=@{type='string';enum=$availablePolicies};policyReason=@{type='string';description='Records existing user/testcase authorization, never an agent justification. Does not enable shortcut capability.'};
            requests=@{type='array';items=@{type='object'};description='Batch: {stepIndex,command,arguments:[]} objects. RecordSteps: {stepIndex,route,observedResult,verificationCommandIds:[]} objects. Structured *Json argument values are supported.'};
            includeImages=@{type='boolean';description='Batch screenshots return their original PNG/JPEG pixels inline by default (last two, <=10 MiB each), alongside receipt/physical region. Inspect these directly without another file-view call. Set false for text-only receipts.'}
        }}}
    @{name='agta_validate';description='Optional read-only standalone replay preflight using saved CSV/policy/manifest; completed exploration required. agta_replay Step/Verify and standalone scripts validate internally, so do not duplicate this check before each execution. Parses source without executing it; never substitutes for a passed run.';
        inputSchema=@{type='object';required=@('runRoot','scriptPath');additionalProperties=$false;properties=@{
            runRoot=@{type='string';description='Absolute existing exploration runRoot.'};scriptPath=@{type='string';description='Absolute generated replay path.'}
        }}}
    @{name='agta_help';description='Read the authoring guide/template once, or targeted CLI/runtime signatures. Use topic authoring first; cli/runtime require observed missing names. Full command receipts and results remain on disk.';
        inputSchema=@{type='object';required=@('topic');additionalProperties=$false;properties=@{
            topic=@{type='string';enum=@('authoring','cli','runtime')};testCaseCsv=@{type='string';description='Authoring context can include the supplied CSV alongside the guide/template.'};names=@{type='array';minItems=1;maxItems=20;items=@{type='string'}};
            detail=@{type='string';enum=@('signatures','full');description='Targeted help defaults to compact signatures; request full only for unresolved behavior.'}
        }}}
    @{name='agta_replay';description='Develop the actual template StepBodies in a persistent live session. Start loads setup without running steps; Step executes only the next body and retains failures/app state. Edit bodies in the saved script, inspect Status, repair live with sequential CLI requests, then retry Step or explicitly Skip. First-attempt successes count; Close qualifies an unchanged, unrepaired all-row first-attempt session without rerunning it. Repaired sessions remain diagnostic; Verify performs one clean full replay after cleanup. Do not invoke generated scripts repeatedly through the shell.';
        inputSchema=@{type='object';required=@('action','runRoot');additionalProperties=$false;properties=@{
            action=@{type='string';enum=@('Start','Step','Repair','Skip','Status','Close','Verify')};runRoot=@{type='string'};
            scriptPath=@{type='string';description='Absolute template-based script path for Start/Verify; Step reloads only saved body edits.'};
            stepIndex=@{type='integer';minimum=1;description='Step only; must equal the next pending row.'};reason=@{type='string';description='Required for diagnostic Skip.'};
            requests=@{type='array';minItems=1;maxItems=20;items=@{type='object';required=@('command','arguments');additionalProperties=$false;properties=@{command=@{type='string'};arguments=@{type='array'}}}};
            includeImages=@{type='boolean';description='Return up to two retained screenshot evidence files inline; default true.'}
        }}}
    @{name='agta_inspect';description='Read bounded structured command diagnostics instead of dumping raw JSONL. Keeps actual error, arguments, target, focus, image metrics and up to 20 discovery elements; no duplicate raw/parsed envelopes. Full records stay on disk.';
        inputSchema=@{type='object';required=@('runRoot');additionalProperties=$false;properties=@{
            runRoot=@{type='string'};source=@{type='string';enum=@('exploration','replay')};last=@{type='integer';minimum=1;maximum=20};stepIndex=@{type='integer';minimum=1}
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
            @($Arguments.requests | Where-Object {$_.command -notin @('observe','select','read','read-pdf','windows','state','screenshot','wait-element','wait-file')}).Count) {
            throw 'Live authoring requires testing the saved body. Save the template, then call agta_explore action Replay, replayAction Start with scriptPath, and replayAction Step. Use Replay Repair for live recovery; Batch is read-only discovery. Do not restart the full script.'
        }
        if ($Arguments.action -eq 'Batch' -and @($planSessions.Values | Where-Object {-not $_.closed}).Count -and
            @($Arguments.requests | Where-Object {$_.command -notin @('observe','select','read','read-pdf','windows','state','screenshot','wait-element','wait-file')}).Count) {
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
            $mode=if ($Arguments.workflowMode) {$Arguments.workflowMode} else {'Live'}
            $savedManifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            $savedManifest | Add-Member -NotePropertyName workflowMode -NotePropertyValue $mode -Force
            $savedManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            $begin=$responses[-1] | ConvertFrom-Json
            $begin | Add-Member -NotePropertyName stepCount -NotePropertyValue @($begin.steps).Count -Force
            $begin.PSObject.Properties.Remove('steps')
            $begin | Add-Member -NotePropertyName workflowMode -NotePropertyValue $mode -Force
            $begin | Add-Member -NotePropertyName replayAvailable -NotePropertyValue $true -Force
            $begin.next=if ($mode -eq 'Live') {'Save template bodies incrementally, then use nextCall and Replay Step (or agta_replay Start/Step). Live replay is available through either name. Batch is read-only; RecordSteps reviews receipts. Close qualifies clean first attempts. No standalone retries during authoring.'} else {'RecordedBatch explicitly selected. Explore with Batch, review RecordSteps, clean owned windows, Complete, then generate the replay. Live Replay remains available.'}
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
        $manifest=[IO.File]::ReadAllText((Join-Path $runKey 'logs\exploration.json')) | ConvertFrom-Json
        if ($manifest.interactionPolicy -eq 'AllowShortcuts' -and -not $EnableShortcutPolicy) {throw 'Shortcut authorization is disabled in this MCP server.'}
        switch -CaseSensitive ($Arguments.action) {
            'Start' {
                if (@($planSessions.Values | Where-Object {-not $_.closed}).Count) {throw 'Close the existing live plan before starting another desktop session.'}
                if (-not $Arguments.scriptPath -or -not [IO.Path]::IsPathRooted($Arguments.scriptPath)) {throw 'Start needs absolute scriptPath.'}
                if ($session) {Remove-Module $session.module -ErrorAction SilentlyContinue}
                $session=Import-AGTAPlanSession $runKey $Arguments.scriptPath
                $planSessions[$runKey]=$session
                Save-AGTAPlanSession $session
                $value=@{ok=$true;runKind='Diagnostic';qualifying=$false;nextStepIndex=1;executionEvidenceRoot=$session.context.ExecutionEvidenceRoot;resultPath=$session.context.ResultPath;next='Write/test the next body with Step. Variables and paths persist. Record reviewed verificationCommandIds with agta_explore RecordSteps.'}
            }
            'Step' {if (-not $session) {throw 'Start the live plan first.'};$value=Invoke-AGTAPlanStep $session -StepIndex $Arguments.stepIndex}
            'Repair' {if (-not $session) {throw 'Start the live plan first.'};$value=@(Invoke-AGTAPlanRepair $session $Arguments.requests)}
            'Skip' {if (-not $session) {throw 'Start the live plan first.'};$value=Skip-AGTAPlanStep $session $Arguments.reason}
            'Status' {if (-not $session) {throw 'Start the live plan first.'};$value=Get-AGTAPlanStatus $session}
            'Close' {if (-not $session) {throw 'Start the live plan first.'};$value=Close-AGTAPlanSession $session}
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
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('runRoot','source','last','stepIndex')) {throw "Unknown inspection argument: $property"}}
        if (-not $Arguments.runRoot -or -not [IO.Path]::IsPathRooted($Arguments.runRoot)) {throw 'Inspection needs an absolute runRoot.'}
        $source=if ($Arguments.source) {$Arguments.source} else {'replay'}
        if ($source -notin @('exploration','replay')) {throw 'Inspection source must be exploration or replay.'}
        $path=if ($source -eq 'exploration') {Join-Path $Arguments.runRoot 'logs\exploration-commands.jsonl'} else {
            $file=Get-ChildItem -LiteralPath (Join-Path $Arguments.runRoot 'logs') -Filter 'potato-commands-*.jsonl' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($file) {$file.FullName} else {$null}
        }
        $last=if ($null -ne $Arguments.last) {[int]$Arguments.last} else {3}
        $value=@{ok=$true;commands=@(Get-AGTACommandDiagnostics $path -Last $last -StepIndex $Arguments.stepIndex);fullLogPath=$path}
        $responses=@(($value | ConvertTo-Json -Depth 40 -Compress))
    } elseif ($Name -eq 'agta_help') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('topic','names','testCaseCsv','detail')) {throw "Unknown help argument: $property"}}
        if ($Arguments.detail -and $Arguments.detail -notin @('signatures','full')) {throw 'Help detail must be signatures or full.'}
        if ($Arguments.topic -eq 'authoring') {
            # Get-Content strings carry provider metadata in PS5. ConvertTo-Json
            # can serialize their PSDrive/.NET object graph instead of plain text.
            $context=@{guide=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'docs\AUTHORING.md'));
                template=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\GeneratedScript.Template.ps1'));
                interactionPolicies=$availablePolicies;shortcutPolicyEnabled=[bool]$EnableShortcutPolicy}
            if ($Arguments.testCaseCsv) {$context.steps=@(Import-Csv -LiteralPath $Arguments.testCaseCsv)}
            $responses=@(($context | ConvertTo-Json -Depth 5 -Compress))
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
        } else {throw 'Help topic must be authoring, cli or runtime.'}
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
                        $reply.result=@{protocolVersion=$version;capabilities=@{tools=@{listChanged=$false}};serverInfo=@{name='agta-exploration';version='1.3.0'}}
                        $negotiated=$true;$ready=$false
                    }
                    'ping' {$reply.result=@{}}
                    'tools/list' {if (-not $ready) {throw 'Initialize the MCP session first.'};$reply.result=@{tools=$tools}}
                    'tools/call' {
                        if (-not $ready) {throw 'Initialize the MCP session first.'}
                        if ($request.params.name -cnotin @('agta_explore','agta_help','agta_validate','agta_replay','agta_inspect')) {$reply.error=@{code=-32602;message='Unknown tool.'};break}
                        try {$reply.result=Invoke-McpTool $request.params.name $request.params.arguments}
                        catch {$reply.result=@{content=@(@{type='text';text=(@{ok=$false;error=$_.Exception.Message;next='Inspect Status/actual GUI before retrying an uncertain dispatch.'} | ConvertTo-Json -Compress)});isError=$true}}
                    }
                    default {$reply.error=@{code=-32601;message='Method not found.'}}
                }
            } catch {$reply.error=@{code=-32602;message=$_.Exception.Message}}
        }
    }
    [Console]::WriteLine((ConvertTo-Json -InputObject $reply -Depth 100 -Compress))
}
