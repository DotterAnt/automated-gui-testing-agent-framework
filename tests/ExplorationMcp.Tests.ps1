param([string]$OutFile,[ValidateRange(3,20)] [int]$Count=6,[switch]$Gui,[switch]$DirectHost)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\ExplorationHost.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-mcp-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$run=Join-Path $root 'run';$server=$null;$child=$null;$script:sequence=0;$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
function Rpc($Method,$Parameters) {
    $script:sequence++
    $json=@{jsonrpc='2.0';id=$script:sequence;method=$Method;params=$Parameters} | ConvertTo-Json -Depth 70 -Compress
    $server.StandardInput.WriteLine($json);$server.StandardInput.Flush()
    $read=$server.StandardOutput.ReadLineAsync()
    if (-not $read.Wait(60000)) {throw "MCP response timed out for $Method"}
    $raw=$read.GetAwaiter().GetResult()
    if (-not $raw) {throw "MCP exited: $($stderr.GetAwaiter().GetResult())"}
    $response=$raw | ConvertFrom-Json
    if ($response.jsonrpc -cne '2.0' -or $response.id -ne $script:sequence) {throw "Unframed stdout or wrong response ID: $raw"}
    $response
}
function Tool($Arguments) {Rpc 'tools/call' @{name='agta_explore';arguments=$Arguments}}
function Values($Response) {@($Response.result.content[0].text -split '\r?\n' | ForEach-Object {$_ | ConvertFrom-Json})}
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Read-only observed fixture' | Set-Content -LiteralPath $csv
    $cliRoot=Join-Path $root 'cli';[void][IO.Directory]::CreateDirectory($cliRoot)
    $source=Join-Path (Split-Path $frameworkRoot) 'potato-cli'
    Copy-Item -LiteralPath (Join-Path $source 'PoTAToCli') -Destination $cliRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $source 'potato.ps1'),(Join-Path $source 'commands.json') -Destination $cliRoot
    $cli=Join-Path $cliRoot 'potato.ps1'
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='powershell.exe';$info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $frameworkRoot 'Invoke-ExplorationMcp.ps1')+'"'
    if ($DirectHost) {$info.Arguments=$info.Arguments.Replace('-NoProfile','-NoProfile -NonInteractive')}
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8
    $server=[Diagnostics.Process]::Start($info);$stderr=$server.StandardError.ReadToEndAsync()
    $early=Rpc 'tools/list' @{}
    Check ([bool]$early.error) 'MCP served tools before initialization.'
    $legacy=Rpc initialize @{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='fixture';version='1'}}
    Check ($legacy.result.protocolVersion -eq '2024-11-05') 'MCP rejected the older supported protocol.'
    $hello=Rpc initialize @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='fixture';version='1'}}
    Check ($hello.result.protocolVersion -eq '2025-06-18' -and $hello.result.capabilities.tools -and $hello.result.serverInfo.version -eq '1.8.1') 'MCP handshake failed or loaded an old server.'
    $server.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');$server.StandardInput.Flush()
    $list=Rpc 'tools/list' @{}
    Check ($list.result.tools.Count -eq 4 -and $list.result.tools[0].inputSchema.required -contains 'runRoot') 'Tool discovery lost input schemas.'
    $validationTool=@($list.result.tools | Where-Object {$_.name -eq 'agta_validate'})
    Check ($validationTool.Count -eq 1 -and $validationTool[0].inputSchema.required -contains 'scriptPath') 'Read-only replay validation was missing from MCP discovery.'
    Check ('AllowShortcuts' -notin $list.result.tools[0].inputSchema.properties.interactionPolicy.enum) 'Default MCP schema exposed agent-enabled shortcuts.'
    $unknown=Rpc 'tools/call' @{name='unknown';arguments=@{}}
    Check ($unknown.error.code -eq -32602) 'Unknown tool was not a protocol error.'
    $unknown=Rpc 'unknown/method' @{}
    Check ($unknown.error.code -eq -32601) 'Unknown method was not a protocol error.'
    $exploreDefault=Join-Path $root 'default-explore'
    $response=Tool @{action='Begin';runRoot=$exploreDefault;testCaseCsv=$csv;potatoCliPath=$cli}
    Check ((Values $response)[0].next -match 'no script is required') 'MCP did not default to exploration before code generation.'
    $response=Tool @{action='Batch';runRoot=$exploreDefault;requests=@(@{stepIndex=1;command='help';arguments=@('-Topic','start')})}
    Check (-not $response.result.isError) 'MCP default required a saved script before exploration.'
    $removed=Rpc 'tools/call' @{name='agta_replay';arguments=@{action='Verify';runRoot=$exploreDefault}}
    Check ($removed.error.code -eq -32602) 'Removed replay tool remained callable.'
    $response=Tool @{action='Replay';runRoot=$exploreDefault}
    Check ($response.result.isError -and (Values $response)[0].error -match 'supported action') 'Removed Replay alias dispatched work.'
    Check (-not (Values $response)[0].location) 'Routine workflow rejection padded source/stack scaffolding.'
    $response=Tool @{action='Begin';runRoot=(Join-Path $root 'removed-live');testCaseCsv=$csv;workflowMode='Live'}
    Check ($response.result.isError -and (Values $response)[0].error -match 'Unknown exploration argument' -and -not (Test-Path (Join-Path $root 'removed-live'))) 'Removed Live mode still initialized a run.'
    Check ('agta_replay' -notin $list.result.tools.name -and 'Replay' -notin $list.result.tools[0].inputSchema.properties.action.enum -and -not $list.result.tools[0].inputSchema.properties.workflowMode) 'Tool discovery retained diagnostic replay surfaces.'
    $response=Tool @{action='Begin';runRoot=$run;testCaseCsv=$csv;potatoCliPath=$cli}
    $begin=(Values $response)[0]
    Check (-not $response.result.isError -and $begin.ok -and $begin.mcpTiming) 'MCP Begin lost timing.'
    $replay=Join-Path $root 'replay.ps1';$marker=Join-Path $root 'must-not-exist.txt'
    ('Set-Content -LiteralPath '''+$marker.Replace("'","''")+''' -Value "must not execute"') | Set-Content -LiteralPath $replay
    $validation=Rpc 'tools/call' @{name='agta_validate';arguments=@{runRoot=$run;scriptPath=$replay}}
    $validationValue=(Values $validation)[0]
    Check ($validation.result.isError -and -not $validationValue.ok -and ($validationValue.issues -join ' ') -match 'incomplete' -and -not (Test-Path $marker)) 'MCP validation executed code or allowed incomplete exploration.'
    $response=Tool @{action='Begin';runRoot=(Join-Path $root 'unauthorized');testCaseCsv=$csv;potatoCliPath=$cli;interactionPolicy='AllowShortcuts'}
    Check ($response.result.isError -and (Values $response)[0].error -match 'authorization') 'MCP bypassed interaction-policy authorization.'
    $response=Tool @{action='Begin';runRoot=(Join-Path $root 'self-authorized');testCaseCsv=$csv;potatoCliPath=$cli;interactionPolicy='AllowShortcuts';policyReason='The application exposes required file actions through accelerators'}
    Check ($response.result.isError -and (Values $response)[0].error -match 'cannot enable' -and -not [IO.File]::Exists((Join-Path $root 'self-authorized\logs\exploration.json'))) 'A model-written reason enabled shortcut capability or initialized an unauthorized run.'
    . (Join-Path $frameworkRoot 'Framework\Exploration.ps1')
    $legacyRun=Join-Path $root 'legacy-shortcut-policy'
    Initialize-AGTAExploration $legacyRun $csv AllowShortcuts $cli | Out-Null
    $response=Tool @{action='Batch';runRoot=$legacyRun;requests=@(@{stepIndex=1;command='help';arguments=@('-Topic','click')})}
    Check ($response.result.isError -and (Values $response)[0].error -match 'disabled' -and -not [IO.File]::Exists((Join-Path $legacyRun 'logs\exploration-commands.jsonl'))) 'An old permissive run bypassed the MCP capability boundary.'
    $response=Tool @{action='Status';runRoot=$legacyRun}
    Check (-not $response.result.isError -and (Values $response)[0].interactionPolicy -eq 'AllowShortcuts') 'Default MCP prevented read-only diagnosis of an old run.'
    $unicode='Fixture '+[char]0x151+[char]0x4e2d
    $response=Tool @{action='Batch';runRoot=$run;requests=@(@{stepIndex=1;command='help';arguments=@('-Topic','type','-WindowSelectorJson',@{Name=$unicode;ClassName='#32770'})})}
    $receipt=Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl') -Tail 1 | ConvertFrom-Json
    Check (-not $response.result.isError -and (Values $response)[0].explorationCommandId -and ($receipt.arguments[3] | ConvertFrom-Json).Name -ceq $unicode) 'MCP changed Unicode/structured guards or lost a real receipt.'
    $response=Tool @{action='Batch';runRoot=$run;requests=@(@{stepIndex=1;command='help';arguments=@('-Topic','missing')},@{stepIndex=1;command='help';arguments=@('-Topic','click')})}
    Check ($response.result.isError -and @(Values $response).Count -eq 1 -and (Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl')).Count -eq 2) "MCP continued a failed batch or lost its failure receipt: $($response | ConvertTo-Json -Depth 7 -Compress)"
    Check ((Values $response)[0].workflow.nextAction -match 'action Status') 'Failed MCP batch did not describe its mandatory review action.'
    $response=Tool @{action='Batch';runRoot=$run;requests=@(@{stepIndex=1;command='help';arguments=@('-Topic','click')})}
    Check ($response.result.isError -and (Values $response)[0].error -match 'Call Status' -and (Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl')).Count -eq 2) 'MCP dispatched an unchecked batch after failure.'
    $response=Tool @{action='Status';runRoot=$run}
    Check (-not $response.result.isError -and (Values $response)[0].commandCount -eq 2) 'Failure killed the MCP server or hid Status.'
    $response=Tool @{action='Batch';runRoot=$run;requests=@(@{stepIndex=1;command='help';arguments=@('-Topic','click')},@{stepIndex=1;command='help';arguments=@('-Topic',@{invalid='object'})})}
    Check ($response.result.isError -and (Get-Content -LiteralPath (Join-Path $run 'logs\exploration-commands.jsonl')).Count -eq 2) 'MCP partially dispatched an invalid batch.'
    Tool @{action='Status';runRoot=$run} | Out-Null
    $response=Tool @{action='RecordSteps';runRoot=$run;requests=@(@{stepIndex=1;route='Fixture';observedResult='Fixture';verificationCommandIds=@('invented')})}
    Check $response.result.isError 'MCP accepted fabricated verification.'
    $response=Tool @{action='Complete';runRoot=$run}
    Check $response.result.isError 'MCP completed missing exploration rows.'
    # Synthetic receipts test transport sealing only, not a user GUI task.
    . (Join-Path $frameworkRoot 'Framework\Exploration.ps1')
    $sealed=Join-Path $root 'sealed'
    Tool @{action='Begin';runRoot=$sealed;testCaseCsv=$csv;potatoCliPath=$cli} | Out-Null
    Add-AGTAExplorationCommand $sealed 1 click @() @{ok=$true} | Out-Null
    $verification=Add-AGTAExplorationCommand $sealed 1 read @() @{ok=$true;data=@{text='Unit fixture'}}
    $recorded=Tool @{action='RecordSteps';runRoot=$sealed;requests=@(@{stepIndex=1;route='Unit fixture route';observedResult='Unit fixture observation';verificationCommandIds=@($verification)})}
    Check (-not $recorded.result.isError -and (Values $recorded)[0].covered -eq 1) 'MCP did not record validated fixture receipts.'
    $complete=Tool @{action='Complete';runRoot=$sealed}
    'Assert-ExpectedResult -Condition $true -Message "Preview"' | Set-Content -LiteralPath $replay
    $validation=Rpc 'tools/call' @{name='agta_validate';arguments=@{runRoot=$sealed;scriptPath=$replay}}
    Check ($validation.result.isError -and ((Values $validation)[0].issues -join ' ') -match 'always passes') 'MCP full preflight ignored a generated assertion error.'
    'Write-Output "read-only fixture"' | Set-Content -LiteralPath $replay
    $validation=Rpc 'tools/call' @{name='agta_validate';arguments=@{runRoot=$sealed;scriptPath=$replay}}
    $validationValue=(Values $validation)[0]
    Check (-not $validation.result.isError -and $validationValue.ok -and -not $validationValue.replayExecuted -and -not $validationValue.taskComplete -and $validationValue.scriptHash -eq (Get-FileHash $replay).Hash) 'MCP static validation claimed replay completion or lost the exact checked revision.'
    Check (-not $complete.result.isError -and (Values $complete)[0].replayReferencePath -and (Test-Path -LiteralPath (Values $complete)[0].replayReferencePath)) 'MCP did not seal and export a verified fixture run.'
    Check ((Values $complete)[0].replayReference.steps[0].commands[0].command -eq 'click' -and -not (Values $complete)[0].routesPath) 'Complete recommended the verbose discovery history instead of returning the compact tested route.'
    $restored=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='replay';runRoot=$sealed;stepIndex=1}}
    Check (-not $restored.result.isError -and (Values $restored)[0].steps.Count -eq 1 -and (Values $restored)[0].steps[0].observedResult -eq 'Unit fixture observation') 'Replay help could not restore the tested row after compaction.'
    $response=Tool @{action='Status';runRoot=$run}
    Check (-not $response.result.isError -and (Values $response)[0].commandCount -eq 2 -and -not $server.HasExited) 'Completing another run killed the server or changed this run.'
    $help=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='runtime';names=@('Invoke-StepCommand','Assert-ZipTextContains','Assert-ImageContainsColors')}}
    Check (-not $help.result.isError -and $help.result.content[0].text -match 'Invoke-StepCommand' -and $help.result.content[0].text -match 'ExpectedEntryCount' -and $help.result.content[0].text -match 'ColorRanges') 'Targeted runtime help failed to publish the content assertions.'
    Add-Type -AssemblyName System.Drawing
    $pixels=[Drawing.Bitmap]::new(12,8);$graphics=[Drawing.Graphics]::FromImage($pixels)
    $pixelPath=Join-Path $root 'existing-image.png'
    try {$graphics.Clear([Drawing.Color]::Green);$pixels.Save($pixelPath,[Drawing.Imaging.ImageFormat]::Png)} finally {$graphics.Dispose();$pixels.Dispose()}
    $pixelHash=(Get-FileHash $pixelPath).Hash
    $inspection=Rpc 'tools/call' @{name='agta_inspect';arguments=@{runRoot=$run;source='image';imagePath=$pixelPath;referencePath=$pixelPath}}
    $measured=(Values $inspection)[0]
    Check (-not $inspection.result.isError -and $measured.metrics.meanError -eq 0 -and $measured.metrics.contentSource -eq 'DecodedImagePixels' -and -not $measured.qualifying -and (Get-FileHash $pixelPath).Hash -eq $pixelHash) 'MCP image diagnosis executed GUI input, changed pixels or claimed a qualifying pass.'
    $inspection=Rpc 'tools/call' @{name='agta_inspect';arguments=@{runRoot=$run;source='image';imagePath=$pixelPath;referencePath=$pixelPath;region=@{x=0;y=0;width=99;height=8}}}
    Check ($inspection.result.isError) 'MCP image diagnosis accepted an out-of-bounds region.'
    $help=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='cli';names=@('type')}}
    Check (-not $help.result.isError -and $help.result.content[0].text -match 'PathKind') 'Targeted CLI help failed.'
    $help=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='authoring';testCaseCsv=$csv}}
    $authoring=(Values $help)[0]
    Check (-not $help.result.isError -and $authoring.guide -is [string] -and $authoring.template -is [string] -and $authoring.steps[0].Action -eq 'Fixture') 'Authoring guide/template/CSV context failed or serialized provider metadata instead of strings.'
    Check ($authoring.guide -ceq [IO.File]::ReadAllText((Join-Path $frameworkRoot 'docs\AUTHORING.md')) -and $authoring.template -ceq [IO.File]::ReadAllText((Join-Path $frameworkRoot 'templates\GeneratedScript.Template.ps1'))) 'MCP changed authoring source content.'
    Check (-not $authoring.shortcutPolicyEnabled -and 'AllowShortcuts' -notin $authoring.interactionPolicies) 'Authoring context lost the active shortcut capability boundary.'
    $response=Rpc 'tools/call' @{name='agta_explore';arguments=@{action='Status';runRoot=$run;Transport='Process'}}
    Check ($response.result.isError -and (Values $response)[0].error -match 'Unknown') 'MCP accepted an unvalidated transport override.'
    $server.StandardInput.WriteLine('{');$server.StandardInput.Flush()
    $parse=$server.StandardOutput.ReadLine() | ConvertFrom-Json
    Check ($parse.error.code -eq -32700) 'Malformed JSON corrupted stdout or killed the server.'

    Check ($authoring.guide -match 'Run the complete saved script' -and $authoring.guide -notmatch 'agta_replay|replayAction|workflowMode|Skip marks') 'Authoring context retained the removed replay workflow.'
    Check ($authoring.guide -match 'existence-only' -and $authoring.guide -match 'Assert-FileWait') 'Authoring context did not permit PDF existence-only assertions.'
    $fullHelp=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='cli';names=@('type');detail='full'}}
    $compactHelp=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='cli';names=@('type')}}
    Check (-not $fullHelp.result.isError -and $fullHelp.result.content[0].text.Length -gt $compactHelp.result.content[0].text.Length -and ($compactHelp.result.content[0].text | ConvertFrom-Json).data.commands.type.usage -match 'PathKind') 'Full behavioral help was unavailable or compact signatures were lost.'
    $ping=Rpc ping @{}
    Check (-not $ping.error -and $ping.result -and -not $server.HasExited) 'MCP did not recover after protocol errors.'
    # An uninterruptible provider must not monopolize the stdio server after a
    # client timeout. This fixture has no GUI or external application effects.
    $stalledRoot=Join-Path $root 'stalled-cli';$stalledModule=Join-Path $stalledRoot 'PoTAToCli'
    [void][IO.Directory]::CreateDirectory($stalledModule)
    $stalledCli=Join-Path $stalledRoot 'potato.ps1';'# Inert fixture entrypoint' | Set-Content $stalledCli
    @'
function Invoke-PotatoCliCommand {
    param($Command,$Arguments,$CliRoot,[switch]$AsObject)
    if ($Command -eq 'observe') {[Threading.Thread]::Sleep(120000)}
    @{ok=$true;command=$Command;data=@{pid=$PID};durationMs=1}
}
Export-ModuleMember -Function Invoke-PotatoCliCommand
'@ | Set-Content (Join-Path $stalledModule 'PoTAToCli.psm1')
    $stalledRun=Join-Path $root 'stalled-run'
    Tool @{action='Begin';runRoot=$stalledRun;testCaseCsv=$csv;potatoCliPath=$stalledCli} | Out-Null
    $stallWatch=[Diagnostics.Stopwatch]::StartNew()
    $stalled=Tool @{action='Batch';runRoot=$stalledRun;requests=@(@{stepIndex=1;command='observe';arguments=@()},@{stepIndex=1;command='state';arguments=@()});includeImages=$false}
    $stalledValue=(Values $stalled)[0]
    Check ($stalled.result.isError -and $stalledValue.error.type -eq 'ProviderTimeout' -and $stalledValue.outcome -eq 'unknown' -and $stallWatch.ElapsedMilliseconds -lt 45000 -and @(Values $stalled).Count -eq 1) 'A stalled provider left MCP blocked or dispatched the rest of the batch.'
    $responsive=Tool @{action='Status';runRoot=$stalledRun}
    Check (-not $responsive.result.isError -and (Values $responsive)[0].commandCount -eq 1 -and -not $server.HasExited) 'Status remained blocked behind the timed-out provider.'
    $progress=Rpc 'tools/call' @{name='agta_inspect';arguments=@{runRoot=$stalledRun;source='exploration'}}
    $progressValue=(Values $progress)[0].providerProgress
    Check ($progressValue.state -eq 'TimedOut' -and $progressValue.command -eq 'observe' -and -not (Get-Process -Id $progressValue.providerPid -ErrorAction SilentlyContinue)) 'MCP timeout lost active-command progress or left its provider running.'
    $healthy=Tool @{action='Batch';runRoot=$stalledRun;requests=@(@{stepIndex=1;command='state';arguments=@()})}
    $ownedProviderPid=(Values $healthy)[0].data.pid
    Check (-not $healthy.result.isError -and $ownedProviderPid -ne $progressValue.providerPid -and @(Get-Content (Join-Path $stalledRun 'logs\exploration-commands.jsonl')).Count -eq 2) 'MCP recovery retried the failed command or could not retain a fresh provider.'
    if ($Gui) {
        $title='AGTA MCP fixture '+[guid]::NewGuid().ToString('N')
        $child=& (Join-Path $PSScriptRoot 'support\Start-ArgumentFixture.ps1') $root $title -Menus
        $guiRun=Join-Path $root 'gui'
        Tool @{action='Begin';runRoot=$guiRun;testCaseCsv=$csv;potatoCliPath=$cli} | Out-Null
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='focus';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000')},
            @{stepIndex=1;command='windows';arguments=@('-Foreground','-WindowTitle',$title,'-TimeoutMs','3000')})}
        $ready=(Values $response)[-1]
        Check (-not $response.result.isError -and $ready.data.count -eq 1) ('MCP could not establish real fixture foreground readiness: '+$response.result.content[0].text)
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='windows';key='current';arguments=@('-Foreground','-WindowTitle',$title,'-TimeoutMs','1000')},
            @{stepIndex=1;command='observe';arguments=@('-Scope','ForegroundWindow','-WindowSelectorJson',@{resultRef='current';path='data.foregroundSelector'},'-FallbackReason','Inspect fixture','-FallbackEvidence','Observed current fixture','-Depth','0','-MaxElements','1')})}
        Check (-not $response.result.isError -and (Values $response)[1].data.root.nativeWindowHandle -eq $ready.data.foregroundSelector.NativeWindowHandle) 'MCP did not bind the fresh window guard inside one batch.'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='windows';key='baseline';arguments=@('-Checkpoint')},
            @{stepIndex=1;command='click';arguments=@('-Name','Fixture File')},
            @{stepIndex=1;command='click';arguments=@('-Name','Fixture Open command')},
            @{stepIndex=1;command='focus';key='newWindow';arguments=@('-WindowTitle','Fixture Open','-SinceCheckpoint',@{resultRef='baseline';path='data.checkpointId'},'-TimeoutMs','3000')},
            @{stepIndex=1;command='close-window';arguments=@('-WindowIdentityJson',@{resultRef='newWindow';path='data.ownedWindow'})})}
        $bound=Values $response
        Check (-not $response.result.isError -and $bound.Count -eq 5 -and $bound[3].data.ownedWindow -and $bound[4].data.closed -eq 1) 'MCP failed to register and close only its new handoff window using returned identities.'
        $receipts=@(Get-Content (Join-Path $guiRun 'logs\exploration-commands.jsonl') | ForEach-Object {$_ | ConvertFrom-Json})
        $focusReceipt=@($receipts | Where-Object {$_.command -eq 'focus'})[-1]
        Check ($focusReceipt.arguments[3] -ceq $bound[0].data.checkpointId -and ($focusReceipt.arguments -join ' ') -notmatch 'resultRef') 'Replay receipts kept a placeholder instead of the actual tested checkpoint argument.'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='focus';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title)},
            @{stepIndex=1;command='focus';arguments=@('-SinceCheckpoint',@{resultRef='notEarlier';path='data.checkpointId'})})}
        Check ($response.result.isError -and @(Values $response).Count -eq 1 -and (Values $response)[0].error -match 'resultRef') ('Invalid later binding was not rejected before dispatch: '+($response | ConvertTo-Json -Depth 8 -Compress))
        Tool @{action='Status';runRoot=$guiRun} | Out-Null
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='click';arguments=@('-Name','Fixture filename','-Method','Mouse')})}
        Check (-not $response.result.isError) 'The handoff fixture did not restore its filename focus for the following typing checks.'
        $imagePath=Join-Path $root 'inline.png'
        $fixtureBounds=$ready.data.windows[0].boundingRectangle
        $stableCapture=@('-X',([string]($fixtureBounds.x+10)),'-Y',([string]($fixtureBounds.y+130)),'-Width','100','-Height','20')
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='screenshot';arguments=@('-OutFile',$imagePath)+$stableCapture})}
        $blocks=@($response.result.content | Where-Object {$_.type -eq 'image'})
        Check (-not $response.result.isError -and $blocks.Count -eq 1 -and $blocks[0].mimeType -eq 'image/png' -and $blocks[0].data -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($imagePath))) 'MCP did not return exact captured screenshot pixels with the receipt.'
        Check ($response.result.content[1].text -match 'physical region' -and (Values $response)[0].data.path -eq $imagePath) 'Inline screenshot lost coordinate origin or its authoritative receipt.'
        $response=Tool @{action='Batch';runRoot=$guiRun;includeImages=$false;requests=@(@{stepIndex=1;command='screenshot';arguments=@('-OutFile',$imagePath)+$stableCapture})}
        Check (-not $response.result.isError -and $response.result.content.Count -eq 1) 'Text-only screenshot option still returned image data.'
        $waitedImage=Join-Path $root 'unmet-visual-wait.png'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='screenshot';arguments=$stableCapture+@('-OutFile',$waitedImage,'-WaitForChangeFrom',$imagePath,'-ChangeRegionJson',@{x=0;y=0;width=100;height=20},'-TimeoutMs','0','-StableMs','0')},
            @{stepIndex=1;command='help';arguments=@('-Topic','click')}
        )}
        Check ($response.result.isError -and @(Values $response).Count -eq 1 -and -not (Values $response)[0].data.conditionMet -and -not (Values $response)[0].verification.eligible -and (Test-Path $waitedImage)) 'MCP continued after an unmet visual wait or lost its final frame.'
        Tool @{action='Status';runRoot=$guiRun} | Out-Null
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='screenshot';arguments=$stableCapture+@('-OutFile',(Join-Path $root 'expected-match.png'),'-WaitForImageMatch',$imagePath,'-MatchRegionJson',@{x=0;y=0;width=100;height=20},'-TimeoutMs','1000','-StableMs','0')})}
        Check (-not $response.result.isError -and (Values $response)[0].data.conditionMet -and (Values $response)[0].data.visualWait.mode -eq 'ExpectedImage' -and @($response.result.content | Where-Object {$_.type -eq 'image'}).Count -eq 1) 'MCP lost expected-image wait options, object region or retained pixels.'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='windows';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-WaitForNotExists','-TimeoutMs','0')})}
        Check ($response.result.isError -and -not (Values $response)[0].data.conditionMet -and -not (Values $response)[0].verification.eligible) 'A real open window passed MCP disappearance evidence.'
        Tool @{action='Status';runRoot=$guiRun} | Out-Null
        $scope=@('-Scope','ForegroundWindow','-WindowSelectorJson',$ready.data.foregroundSelector,'-FallbackReason','Actual generic MCP fixture','-FallbackEvidence',$ready.explorationCommandId)
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='observe';arguments=$scope+@('-Depth','0','-MaxElements','1')})}
        Check (-not $response.result.isError -and (Values $response)[0].data.focusedElement.id -eq 'Filename') 'MCP focus-only observation lost the actual field.'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='screenshot';arguments=$scope+@('-OutFile',(Join-Path $root 'guarded-window.png'))})}
        Check (-not $response.result.isError -and (Values $response)[0].data.region.width -gt 100 -and @($response.result.content | Where-Object {$_.type -eq 'image'}).Count -eq 1) 'MCP rejected/ignored guarded foreground screenshot or lost its inline pixels.'
        $path=Join-Path $root ($unicode+'.docx')
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='type';arguments=$scope+@('-AutomationId','Filename','-Text',$path,'-PathKind','SaveFile','-PreDelete','-Verify','-TimeoutMs','1000')})}
        $typed=(Values $response)[0]
        Check (-not $response.result.isError -and $typed.data.verified) 'MCP actual guarded Unicode filename typing failed.'
        $wrong=@($scope);$wrong[3]=@{Name='Wrong fixture';ClassName=$ready.data.foregroundSelector.ClassName;ProcessId=$child.Id}
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='type';arguments=$wrong+@('-AutomationId','Filename','-Text','must not be sent','-TimeoutMs','0')})}
        $blocked=(Values $response)[0]
        Check ($response.result.isError -and $blocked.error.type -eq 'ScopeNotReady' -and $blocked.outcome -eq 'not-dispatched') 'MCP weakened the actual foreground guard.'
        Tool @{action='Status';runRoot=$guiRun} | Out-Null
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='read';arguments=$scope+@('-AutomationId','Filename','-TimeoutMs','1000')})}
        $read=(Values $response)[0]
        Check (-not $response.result.isError -and $read.data.text -ceq $path) 'Rejected MCP input changed the real field.'
        foreach ($route in @(@{command='Fixture Open command';dialog='Fixture Open'},@{command='Fixture Print command';dialog='Fixture Print'})) {
            $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
                @{stepIndex=1;command='click';arguments=@('-Name','Fixture File','-ControlType','MenuItem')},
                @{stepIndex=1;command='wait-element';arguments=@('-Name',$route.command,'-TimeoutMs','1500')})}
            Check (-not $response.result.isError -and (Values $response)[-1].data.exists) ('MCP did not open the actual visible menu: '+$response.result.content[0].text)
            $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
                @{stepIndex=1;command='click';arguments=@('-Name',$route.command,'-ControlType','MenuItem')},
                @{stepIndex=1;command='windows';arguments=@('-Foreground','-WindowTitle',$route.dialog,'-TimeoutMs','3000')})}
            $dialog=(Values $response)[-1]
            Check (-not $response.result.isError -and $dialog.data.count -eq 1 -and $dialog.data.foregroundSelector.Name -eq $route.dialog) ('MCP menu action did not open its actual dialog: '+$response.result.content[0].text)
            $dialogScope=@('-Scope','ForegroundWindow','-WindowSelectorJson',$dialog.data.foregroundSelector,'-FallbackReason','Observed fixture modal','-FallbackEvidence',$dialog.explorationCommandId)
            $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
                @{stepIndex=1;command='click';arguments=$dialogScope+@('-Name','Fixture Cancel','-ControlType','Button')},
                @{stepIndex=1;command='windows';arguments=@('-Foreground','-WindowTitle',$title,'-TimeoutMs','3000')})}
            Check (-not $response.result.isError -and (Values $response)[-1].data.count -eq 1) 'MCP did not close the actual menu dialog through its visible button.'
        }
        Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='focus';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title)})} | Out-Null
        $response=Tool @{action='RecordSteps';runRoot=$guiRun;requests=@(@{stepIndex=1;route='Focused observed fixture, typed and read literal filename';observedResult='Actual Unicode path read back';verificationCommandIds=@($typed.explorationCommandId,$read.explorationCommandId)})}
        Check (-not $response.result.isError) 'MCP could not record actual GUI verification receipts.'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='close-window';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','5000')},
            @{stepIndex=1;command='windows';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-WaitForNotExists','-TimeoutMs','5000')})}
        $gone=(Values $response)[-1]
        Check (-not $response.result.isError -and $gone.data.conditionMet -and $gone.verification.eligible -and $gone.durationMs -lt 4000 -and $child.WaitForExit(3000)) 'MCP did not promptly verify its real fixture disappearance.'
        $response=Tool @{action='Complete';runRoot=$guiRun}
        Check (-not $response.result.isError -and (Values $response)[0].replayReferencePath) 'MCP did not complete the actual GUI fixture.'
    }
    $state=@(@{stepIndex=1;command='state';arguments=@()})
    Tool @{action='Batch';runRoot=$run;requests=$state} | Out-Null
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1';$json=ConvertTo-Json -InputObject $state -Depth 10 -Compress
    & $entry -Action Batch -RunRoot $run -RequestsJson $json | Out-Null
    $literalEntry="'"+$entry.Replace("'","''")+"'";$literalRun="'"+$run.Replace("'","''")+"'";$literalJson="'"+$json.Replace("'","''")+"'"
    $code='$ProgressPreference="SilentlyContinue"; '+"& $literalEntry -Action Batch -RunRoot $literalRun -RequestsJson $literalJson"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $samples=@()
    for ($i=0;$i -lt $Count;$i++) {
        $modes=if ($i%2) {@('Mcp','FreshShellDirect')} else {@('FreshShellDirect','Mcp')}
        foreach ($mode in $modes) {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            if ($mode -eq 'Mcp') {
                $response=Tool @{action='Batch';runRoot=$run;requests=$state}
                $elapsed=$watch.Elapsed.TotalMilliseconds;$result=(Values $response)[0]
                if ($response.result.isError -or -not $result.ok) {throw 'MCP benchmark failed.'}
            } else {
                $raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
                $elapsed=$watch.Elapsed.TotalMilliseconds;$result=$raw | ConvertFrom-Json
                if ($LASTEXITCODE -ne 0 -or -not $result.ok) {throw 'Fresh shell benchmark failed.'}
            }
            $samples+=,@{mode=$mode;wallMs=[Math]::Round($elapsed,2);cliMs=$result.totalDurationMs}
        }
    }
    $server.StandardInput.Close()
    Check ($server.WaitForExit(5000) -and $server.ExitCode -eq 0) 'EOF left an MCP worker running.'
    $exitWatch=[Diagnostics.Stopwatch]::StartNew()
    while ((Get-Process -Id $ownedProviderPid -ErrorAction SilentlyContinue) -and $exitWatch.ElapsedMilliseconds -lt 4000) {Start-Sleep -Milliseconds 50}
    Check (-not (Get-Process -Id $ownedProviderPid -ErrorAction SilentlyContinue)) 'Retained CLI worker survived its MCP parent exit.'
    $primaryServerId=$server.Id;$server.Dispose()
    # Operator opt-in is a startup setting, never a tool-call argument. No GUI
    # shortcut is sent in this capability/authorization test.
    $info.Arguments+=' -EnableShortcutPolicy'
    $server=[Diagnostics.Process]::Start($info);$stderr=$server.StandardError.ReadToEndAsync()
    Rpc initialize @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='operator-fixture';version='1'}} | Out-Null
    $server.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');$server.StandardInput.Flush()
    $list=Rpc 'tools/list' @{}
    Check ('AllowShortcuts' -in $list.result.tools[0].inputSchema.properties.interactionPolicy.enum) 'Operator-enabled shortcut capability was unavailable.'
    $response=Tool @{action='Begin';runRoot=(Join-Path $root 'operator-without-reason');testCaseCsv=$csv;potatoCliPath=$cli;interactionPolicy='AllowShortcuts'}
    Check ($response.result.isError -and (Values $response)[0].error -match 'authorization') 'Operator capability removed the per-run authorization record.'
    $response=Tool @{action='Begin';runRoot=(Join-Path $root 'operator-authorized');testCaseCsv=$csv;potatoCliPath=$cli;interactionPolicy='AllowShortcuts';policyReason='Explicit user authorization fixture'}
    Check (-not $response.result.isError -and (Values $response)[0].ok) 'Operator capability plus recorded authorization failed.'
    # Abrupt parent termination must not leave the compatibility host/provider
    # alive with inherited protocol pipes held open.
    $operatorRoot=Join-Path $root 'operator-authorized'
    Tool @{action='Batch';runRoot=$operatorRoot;requests=@(@{stepIndex=1;command='state';arguments=@()})} | Out-Null
    $operatorProgress=Rpc 'tools/call' @{name='agta_inspect';arguments=@{runRoot=$operatorRoot;source='exploration'}}
    $operatorProvider=(Values $operatorProgress)[0].providerProgress.providerPid
    $server.Kill();[void]$server.WaitForExit(3000)
    $orphanWatch=[Diagnostics.Stopwatch]::StartNew()
    while ((Get-Process -Id $operatorProvider -ErrorAction SilentlyContinue) -and $orphanWatch.ElapsedMilliseconds -lt 5000) {Start-Sleep -Milliseconds 50}
    Check (-not (Get-Process -Id $operatorProvider -ErrorAction SilentlyContinue)) 'An abruptly terminated MCP parent left its host/provider running.'
    Check ($server.StandardOutput.ReadToEndAsync().Wait(3000)) 'An orphan compatibility host retained protocol stdout after its parent exited.'
    $result=@{checks=$script:checks;gui=[bool]$Gui;directHost=[bool]$DirectHost;guiDisappearanceMs=$(if ($Gui) {$gone.durationMs});samples=$samples;serverProcessId=$primaryServerId;powershell=$PSVersionTable.PSVersion.ToString();
        note='Sequential real read-only state receipts. MCP uses one persistent PS5 process; FreshShellDirect creates a NoProfile PS5 caller and reuses the Auto worker. Excludes external agent/tool transport and one-time initialization.'}
    if ($OutFile) {$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8}
    $result | ConvertTo-Json -Depth 6 -Compress
} finally {
    if ($child -and -not $child.HasExited) {Stop-Process -Id $child.Id -ErrorAction SilentlyContinue}
    if ($server) {if (-not $server.HasExited) {$server.Kill();$server.WaitForExit()};$server.Dispose()}
    Invoke-AGTAExplorationHost $run @{} -Stop | Out-Null
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-mcp-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
