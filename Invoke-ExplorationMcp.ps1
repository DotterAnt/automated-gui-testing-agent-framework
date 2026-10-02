[CmdletBinding()]
param([switch]$EnableShortcutPolicy)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+$env:PSModulePath
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$entry=Join-Path $PSScriptRoot 'Invoke-Exploration.ps1'
$ready=$false
$negotiated=$false
$reviewRequired=@{}
$availablePolicies=@('GuiNavigation','VisibleControls')
if ($EnableShortcutPolicy) {$availablePolicies+=,'AllowShortcuts'}
$tools=@(
    @{name='agta_explore';description='Recorded GUI exploration in a persistent process. Use visible controls for application actions; a model-written policyReason cannot authorize shortcuts. Begin once with a unique absolute runRoot/testCaseCsv. Batch up to 20 known sequential commands, ending at an observation for unknown transitions. RecordSteps only with verification.eligible receipts after reviewing them. Close owned windows before Complete. After a failed Batch, call Status and inspect the outcome before a separate recovery Batch.';
        inputSchema=@{type='object';required=@('action','runRoot');additionalProperties=$false;properties=@{
            action=@{type='string';enum=@('Begin','Batch','RecordSteps','Status','Complete')};runRoot=@{type='string'};
            testCaseCsv=@{type='string'};potatoCliPath=@{type='string'};
            interactionPolicy=@{type='string';enum=$availablePolicies};policyReason=@{type='string';description='Records existing user/testcase authorization, never an agent justification. Does not enable shortcut capability.'};
            requests=@{type='array';items=@{type='object'};description='Batch: {stepIndex,command,arguments:[]} objects. RecordSteps: {stepIndex,route,observedResult,verificationCommandIds:[]} objects. Structured *Json argument values are supported.'}
        }}}
    @{name='agta_help';description='Read the authoring guide/template once, or targeted CLI/runtime signatures. Use topic authoring first; cli/runtime require observed missing names. Full command receipts and results remain on disk.';
        inputSchema=@{type='object';required=@('topic');additionalProperties=$false;properties=@{
            topic=@{type='string';enum=@('authoring','cli','runtime')};testCaseCsv=@{type='string';description='Authoring context can include the supplied CSV alongside the guide/template.'};names=@{type='array';minItems=1;maxItems=20;items=@{type='string'}}
        }}}
)
function Invoke-McpTool($Name,$Arguments) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    if (-not $Arguments -or $Arguments -is [array] -or $Arguments -isnot [pscustomobject]) {throw 'Tool arguments must be an object.'}
    $global:LASTEXITCODE=0
    if ($Name -eq 'agta_explore') {
        $allowed=@('action','runRoot','testCaseCsv','potatoCliPath','interactionPolicy','policyReason','requests')
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin $allowed) {throw "Unknown exploration argument: $property"}}
        if ($Arguments.action -cnotin @('Begin','Batch','RecordSteps','Status','Complete') -or -not $Arguments.runRoot -or -not [IO.Path]::IsPathRooted($Arguments.runRoot)) {throw 'Use a supported action and an absolute runRoot.'}
        $runKey=[IO.Path]::GetFullPath($Arguments.runRoot)
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
            $begin=$responses[-1] | ConvertFrom-Json
            $begin.next='Keep this runRoot. Call agta_explore Batch with requests [{stepIndex,command,arguments:[]}]. Reuse observed selectors and guards; keep desktop commands sequential. Use explorationEvidenceRoot/full paths/PathKind. Review verification receipts, RecordSteps, clean up, Complete, then generate and execute the replay. agta_help provides targeted signatures.'
            $responses[-1]=$begin | ConvertTo-Json -Depth 80 -Compress
        }
    } elseif ($Name -eq 'agta_help') {
        foreach ($property in $Arguments.PSObject.Properties.Name) {if ($property -cnotin @('topic','names','testCaseCsv')) {throw "Unknown help argument: $property"}}
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
            if ($Arguments.topic -eq 'cli') {$responses=@(& (Join-Path (Split-Path $PSScriptRoot) 'potato-cli\potato.ps1') help -Topics $names)}
            else {$responses=@(& (Join-Path $PSScriptRoot 'Get-RuntimeHelp.ps1') -Names $names)}
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
        $final | Add-Member -NotePropertyName mcpTiming -NotePropertyValue @{requestMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,2)} -Force
        $responses[$last]=$final | ConvertTo-Json -Depth 80 -Compress
    }
    @{content=@(@{type='text';text=$responses -join "`n"});isError=$failed}
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
                        $reply.result=@{protocolVersion=$version;capabilities=@{tools=@{listChanged=$false}};serverInfo=@{name='agta-exploration';version='1.0.2'}}
                        $negotiated=$true;$ready=$false
                    }
                    'ping' {$reply.result=@{}}
                    'tools/list' {if (-not $ready) {throw 'Initialize the MCP session first.'};$reply.result=@{tools=$tools}}
                    'tools/call' {
                        if (-not $ready) {throw 'Initialize the MCP session first.'}
                        if ($request.params.name -cnotin @('agta_explore','agta_help')) {$reply.error=@{code=-32602;message='Unknown tool.'};break}
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
