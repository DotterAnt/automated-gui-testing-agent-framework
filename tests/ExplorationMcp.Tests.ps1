param([string]$OutFile,[ValidateRange(3,20)] [int]$Count=6,[switch]$Gui)
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
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8
    $server=[Diagnostics.Process]::Start($info);$stderr=$server.StandardError.ReadToEndAsync()
    $early=Rpc 'tools/list' @{}
    Check ([bool]$early.error) 'MCP served tools before initialization.'
    $legacy=Rpc initialize @{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='fixture';version='1'}}
    Check ($legacy.result.protocolVersion -eq '2024-11-05') 'MCP rejected the older supported protocol.'
    $hello=Rpc initialize @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='fixture';version='1'}}
    Check ($hello.result.protocolVersion -eq '2025-06-18' -and $hello.result.capabilities.tools) 'MCP handshake failed.'
    $server.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');$server.StandardInput.Flush()
    $list=Rpc 'tools/list' @{}
    Check ($list.result.tools.Count -eq 2 -and $list.result.tools[0].inputSchema.required -contains 'runRoot') 'Tool discovery lost input schemas.'
    Check ('AllowShortcuts' -notin $list.result.tools[0].inputSchema.properties.interactionPolicy.enum) 'Default MCP schema exposed agent-enabled shortcuts.'
    $unknown=Rpc 'tools/call' @{name='unknown';arguments=@{}}
    Check ($unknown.error.code -eq -32602) 'Unknown tool was not a protocol error.'
    $unknown=Rpc 'unknown/method' @{}
    Check ($unknown.error.code -eq -32601) 'Unknown method was not a protocol error.'
    $response=Tool @{action='Begin';runRoot=$run;testCaseCsv=$csv;potatoCliPath=$cli}
    $begin=(Values $response)[0]
    Check (-not $response.result.isError -and $begin.ok -and $begin.next -match 'agta_explore' -and $begin.mcpTiming) 'MCP Begin lost configuration/timing or advertised the shell transport.'
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
    Check (-not $complete.result.isError -and (Values $complete)[0].replayReferencePath -and (Test-Path -LiteralPath (Values $complete)[0].replayReferencePath)) 'MCP did not seal and export a verified fixture run.'
    $response=Tool @{action='Status';runRoot=$run}
    Check (-not $response.result.isError -and (Values $response)[0].commandCount -eq 2 -and -not $server.HasExited) 'Completing another run killed the server or changed this run.'
    $help=Rpc 'tools/call' @{name='agta_help';arguments=@{topic='runtime';names=@('Invoke-StepCommand','Assert-ZipTextContains','Assert-ImageContainsColors')}}
    Check (-not $help.result.isError -and $help.result.content[0].text -match 'Invoke-StepCommand' -and $help.result.content[0].text -match 'ExpectedEntryCount' -and $help.result.content[0].text -match 'ColorRanges') 'Targeted runtime help failed to publish the content assertions.'
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
    $ping=Rpc ping @{}
    Check (-not $ping.error -and $ping.result -and -not $server.HasExited) 'MCP did not recover after protocol errors.'
    if ($Gui) {
        $title='AGTA MCP fixture '+[guid]::NewGuid().ToString('N')
        $child=& (Join-Path $PSScriptRoot 'support\Start-ArgumentFixture.ps1') $root $title -Menus
        $guiRun=Join-Path $root 'gui'
        Tool @{action='Begin';runRoot=$guiRun;testCaseCsv=$csv;potatoCliPath=$cli} | Out-Null
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(
            @{stepIndex=1;command='focus';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-TimeoutMs','10000')},
            @{stepIndex=1;command='windows';arguments=@('-Foreground','-WindowTitle',$title,'-TimeoutMs','3000')})}
        $ready=(Values $response)[-1]
        Check (-not $response.result.isError -and $ready.data.count -eq 1) 'MCP could not establish real fixture foreground readiness.'
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='windows';arguments=@('-ProcessId',"$($child.Id)",'-WindowTitle',$title,'-WaitForNotExists','-TimeoutMs','0')})}
        Check ($response.result.isError -and -not (Values $response)[0].data.conditionMet -and -not (Values $response)[0].verification.eligible) 'A real open window passed MCP disappearance evidence.'
        Tool @{action='Status';runRoot=$guiRun} | Out-Null
        $scope=@('-Scope','ForegroundWindow','-WindowSelectorJson',$ready.data.foregroundSelector,'-FallbackReason','Actual generic MCP fixture','-FallbackEvidence',$ready.explorationCommandId)
        $response=Tool @{action='Batch';runRoot=$guiRun;requests=@(@{stepIndex=1;command='observe';arguments=$scope+@('-Depth','0','-MaxElements','1')})}
        Check (-not $response.result.isError -and (Values $response)[0].data.focusedElement.id -eq 'Filename') 'MCP focus-only observation lost the actual field.'
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
    $server.StandardInput.Close();Check ($server.WaitForExit(5000) -and $server.ExitCode -eq 0) 'Opt-in MCP server did not close on EOF.'
    $result=@{checks=$script:checks;gui=[bool]$Gui;guiDisappearanceMs=$(if ($Gui) {$gone.durationMs});samples=$samples;serverProcessId=$primaryServerId;powershell=$PSVersionTable.PSVersion.ToString();
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
