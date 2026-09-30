param()
$ErrorActionPreference = 'Stop'
$frameworkRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agta-regression-' + [guid]::NewGuid())
$cliPath = Join-Path (Split-Path -Parent $frameworkRoot) 'potato-cli\potato.ps1'
$script:checks=0
function Check($ok,$message) { if (-not $ok) { throw $message }; $script:checks++ }
function Invoke-EvidenceScreenshot { throw 'Fixture: desktop capture disabled.' }
New-Item -ItemType Directory $testRoot | Out-Null
try {
    $csv=Join-Path $testRoot 'case.csv'
    'Action,Data,Expected Result', 'Check fixture,,Fixture verified' | Set-Content $csv
    Initialize-AGTAExploration $testRoot $csv GuiNavigation | Out-Null
    Add-AGTAExplorationCommand $testRoot 1 click @() @{ok=$true;interactionPolicy=@{mode='GuiNavigation'}} | Out-Null
    $receipt=Add-AGTAExplorationCommand $testRoot 1 read @() @{ok=$true;data=@{text='Fixture verified'}}
    Complete-AGTAExplorationStep $testRoot 1 'Synthetic test fixture route' 'Fixture verified' $receipt | Out-Null
    Complete-AGTAExploration $testRoot $csv GuiNavigation | Out-Null
    $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot
    Push-Location $testRoot
    try {
        $relative=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv '.\case.csv' -RunRoot '.\relative run' -ExplorationPath '.\logs\exploration.json'
        Check ($relative.RunRoot -eq (Join-Path $testRoot 'relative run') -and $relative.ExecutionEvidenceRoot.StartsWith($relative.RunRoot) -and [IO.Path]::IsPathRooted($relative.ExecutionEvidenceRoot)) 'Runtime retained relative GUI output paths or used the process cwd instead of PowerShell location.'
        Check ($relative.TestCaseCsv -eq $csv -and [IO.Path]::IsPathRooted($relative.CommandLogPath) -and [IO.Path]::IsPathRooted($relative.ExplorationPath)) 'Runtime left relative input/log/manifest paths in the context.'
    } finally { Pop-Location }
    $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot
    $helper=Get-AGTARuntimeHelp -Name Assert-ArtifactPrefix
    Check ($helper.available -and $helper.sourcePath -like '*ArtifactAssertions.ps1' -and $helper.syntax -match 'ExpectedBytes') 'Imported artifact helper was hidden from runtime help.'
    $helpRaw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Get-RuntimeHelp.ps1') -Name Assert-FileWait
    $helpValue=@($helpRaw | ConvertFrom-Json)[0]
    Check ($LASTEXITCODE -eq 0 -and $helpValue.syntax -match 'Message') 'Runtime help entrypoint failed or truncated the signature.'
    $preflight=Test-AGTAGeneratedScript -ScriptPath (Join-Path $frameworkRoot 'templates\GeneratedScript.Template.ps1') -TestCaseCsv $csv -PotatoCliPath $cliPath
    Check $preflight.ok 'Template failed static helper/input preflight.'
    $preflightRaw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Test-GeneratedScript.ps1') -ScriptPath (Join-Path $frameworkRoot 'templates\GeneratedScript.Template.ps1') -TestCaseCsv $csv -PotatoCliPath $cliPath
    $preflightValue=$preflightRaw | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and $preflightValue.ok) 'Preflight entrypoint failed on the template.'
    $wrong=Join-Path $testRoot 'wrong-helper.ps1'
    'Assert-ArtifactPrefx -Path x -ExpectedBytes ([byte[]]@(1))' | Set-Content $wrong
    $preflight=Test-AGTAGeneratedScript -ScriptPath $wrong -TestCaseCsv $csv -PotatoCliPath $cliPath
    Check (-not $preflight.ok -and @($preflight.issues | Where-Object { $_ -match 'unavailable' }).Count -eq 1) 'Unknown helper survived preflight.'
    $invalidRaw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Test-GeneratedScript.ps1') -ScriptPath $wrong
    $invalidValue=$invalidRaw | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 1 -and -not $invalidValue.ok -and $invalidValue.issues[0] -match 'unavailable') 'Preflight entrypoint did not report an invalid script.'
    'Assert-ArtifactPrefix -Path x -ExpectBytes ([byte[]]@(1))' | Set-Content $wrong
    $preflight=Test-AGTAGeneratedScript -ScriptPath $wrong
    Check (-not $preflight.ok -and $preflight.issues[0] -match 'parameter') 'Wrong helper argument survived preflight.'
    '[System.IO.File]::ReadAllBytes($Path)' | Set-Content $wrong
    $preflight=Test-AGTAGeneratedScript -ScriptPath $wrong
    Check (-not $preflight.ok -and @($preflight.issues | Where-Object { $_ -match 'ReadAllBytes' }).Count -eq 1) 'Unsafe bulk artifact read survived preflight.'
    '[IO.File]::ReadAllBytes($Path)' | Set-Content $wrong
    $preflight=Test-AGTAGeneratedScript -ScriptPath $wrong
    Check (-not $preflight.ok -and @($preflight.issues | Where-Object { $_ -match 'ReadAllBytes' }).Count -eq 1) 'Short file-type alias survived bulk-read preflight.'
    Assert-FileWait -Result ([pscustomobject]@{ok=$true;data=@{path=$csv;conditionMet=$true}}) -Message 'Fixture file should exist.'
    $fileWaitFailed=$false
    try { Assert-FileWait -Result ([pscustomobject]@{ok=$true;data=@{path=$csv;conditionMet=$false}}) -Message 'Fixture wait failed.' } catch { $fileWaitFailed=$_.Exception.Message -eq 'Fixture wait failed.' }
    Check $fileWaitFailed 'File wait did not infer the path or honor a custom assertion message.'
    Check ($ctx.InteractionPolicy -eq 'GuiNavigation' -and $ctx.RequireAssertions -and $ctx.Transport -eq 'InProcess') 'Defaults are inconsistent.'
    $focusSummary=New-CommandSummary type @() @{ok=$false;outcome='not-dispatched';error=@{type='InputFocusNotReady';message='Fixture focus mismatch';focus=@{owned=$false;focusHandle=123}}}
    Check ($focusSummary.errorType -eq 'InputFocusNotReady' -and $focusSummary.inputFocus.focusHandle -eq 123 -and -not $focusSummary.inputFocus.owned -and $focusSummary.outcome -eq 'not-dispatched') 'Compact command summary dropped the actionable focus diagnosis.'
    $help=Invoke-PotatoJson help @('-Topic','type')
    Check ($help.ok -and $ctx.Timing.commandCount -eq 1) 'In-process transport/timing failed.'
    $realModule=$ctx.CliModule
    $fixtureModule=New-Module -ScriptBlock {
        function Invoke-PotatoCliCommand {
            param($Command,$Arguments,$CliRoot,[switch]$AsObject)
            $position=[array]::IndexOf($Arguments,'-Format')
            @{ok=$true;command=$Command;durationMs=0;data=@{format=$(if ($position -ge 0) {$Arguments[$position+1]} else {'Full'})}}
        }
        Export-ModuleMember Invoke-PotatoCliCommand
    }
    $ctx.CliModule=$fixtureModule
    try {
        $defaultObserve=Invoke-PotatoJson observe @('-Depth','3')
        Check ($defaultObserve.data.format -eq 'Compact') 'Generated observation default differs from exploration.'
        $fullObserve=Invoke-PotatoJson observe @('-Format','Full')
        Check ($fullObserve.data.format -eq 'Full') 'Explicit full observation was overridden.'
        $lastLog=Get-Content $ctx.CommandLogPath -Tail 2 | ForEach-Object {$_ | ConvertFrom-Json}
        Check ($lastLog[0].arguments -contains 'Compact' -and $lastLog[1].arguments -contains 'Full') 'Runtime transcript hid effective observation arguments.'
    } finally {$ctx.CliModule=$realModule;Remove-Module $fixtureModule}
    $blocked=Invoke-PotatoJson hotkey @('-Keys','^s')
    Check (-not $blocked.ok -and -not $ctx.PolicyCompliant) 'Blocked policy did not invalidate the run.'
    $pass=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-ExpectedResult $true 'Fixture verified' }
    $final=Complete-AGTAGeneratedTest @($pass) @() -PassThru
    Check (-not $final.ok -and (Get-AGTATestExitCode) -eq 1) 'Policy violation allowed aggregate PASS.'
    $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot
    $caught=$false
    try { Invoke-PotatoJson help @('-InteractionPolicy=AllowShortcuts') | Out-Null } catch {$caught=$true}
    Check ($caught -and -not $ctx.PolicyCompliant) 'Per-command policy override accepted.'
    $caught=$false
    try { Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot -InteractionPolicy AllowShortcuts | Out-Null } catch {$caught=$true}
    Check $caught 'Relaxed policy accepted without authorization record.'
    $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot
    $failed=Invoke-RecordedStep 1 { param($Commands,$Evidence) try { Assert-ExpectedResult $false 'Missing artifact' } catch {} }
    Check ($failed.status -eq 'FAIL') 'Caught assertion turned into PASS.'
    $missing=Invoke-RecordedStep 1 { param($Commands,$Evidence) }
    Check ($missing.status -eq 'FAIL') 'No assertion turned into PASS.'
    $readback=@{ok=$true;command='read';data=@{text="Title`r`nBody text";textSource='TextPattern'}}
    $content=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-TextContains $readback @("Title`nBody",'text') }
    Check ($content.status -eq 'PASS') 'Content assertion did not normalize line endings or verify all fragments.'
    $content=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-TextContains $readback @('Title','missing paragraph') }
    Check ($content.status -eq 'FAIL') 'Missing paragraph passed content assertion.'
    $readback.data.textSource='Name'
    $content=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-TextContains $readback @('Title') }
    Check ($content.status -eq 'FAIL') 'Accessible element name was accepted as document content.'
    $readback.command='read-pdf'
    $content=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-TextContains $readback @('Body text') }
    Check ($content.status -eq 'PASS') 'Read-only PDF content was rejected.'
    $final=Complete-AGTAGeneratedTest @($pass) @(@{ok=$false;error='cleanup fixture'}) -PassThru
    Check (-not $final.ok -and (Get-AGTATestExitCode) -eq 1) 'Cleanup failure passed.'
    Check (-not $final.summary.cleanupOk) 'Concise result summary hid failed cleanup.'
    $final=Complete-AGTAGeneratedTest @() @() -PassThru
    Check (-not $final.ok -and -not $final.coverageOk) 'Missing CSV row passed.'
    $final=Complete-AGTAGeneratedTest @($pass,$pass) @() -PassThru
    Check (-not $final.ok -and -not $final.coverageOk) 'Duplicated CSV row passed.'
    $final=Complete-AGTAGeneratedTest @($pass) @() -PassThru
    Check ($final.ok -and (Get-AGTATestExitCode) -eq 0) 'Valid run failed.'
    Check ($final.timing.totalMs -ge $final.timing.wrapperMs) 'Timings do not reconcile.'
    $file=Join-Path $testRoot 'held.bin'
    $writer=[IO.File]::Open($file,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    try {
        $writer.WriteByte(42); $writer.WriteByte(43); $writer.Flush()
        $bytes=Read-AGTAArtifactBytes $file -Count 2 -TimeoutMs 0
        Check ($bytes[0] -eq 42 -and $bytes[1] -eq 43) 'Shared artifact read failed.'
        $good=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-ArtifactPrefix $file ([byte[]]@(42,43)) }
        Check ($good.status -eq 'PASS') 'Valid signature failed.'
        $bad=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-ArtifactPrefix $file ([byte[]]@(1,2)) }
        Check ($bad.status -eq 'FAIL') 'Wrong signature passed.'
    }
    finally {$writer.Dispose()}
    $writer=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $caught=$false; try { Read-AGTAArtifactBytes $file -Count 1 -TimeoutMs 0 | Out-Null } catch {$caught=$true}
        Check $caught 'Exclusive lock became successful verification.'
    }
    finally {$writer.Dispose()}
    # Process mode uses exactly the same CLI policy and data contract.
    $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot -Transport Process
    Check (Invoke-PotatoJson help @('-Topic','type')).ok 'Process transport failed.'
    $blocked=Invoke-PotatoJson type @('-Text','x','-PreDelete','-ClearMethod','Shortcut')
    Check (-not $blocked.ok -and -not $ctx.PolicyCompliant) 'Process transport bypassed policy.'
    # Child entrypoint must emit one JSON result and propagate failure as process exit.
    $runner=Join-Path $testRoot 'exit-fixture.ps1'
    @'
param($Runtime,$Cli,$Csv,$Root,[int]$Pass)
. $Runtime
$ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $Cli -TestCaseCsv $Csv -RunRoot $Root
function Invoke-EvidenceScreenshot { throw 'Fixture' }
$step=Invoke-RecordedStep 1 { param($Commands,$Evidence) Assert-ExpectedResult ([bool]$Pass) 'Fixture verified' }
Complete-AGTAGeneratedTest @($step) @()
exit (Get-AGTATestExitCode)
'@ | Set-Content $runner
    foreach ($success in @(0,1)) {
        $raw=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Runtime (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1') -Cli $cliPath -Csv $csv -Root $testRoot -Pass $success
        $code=$LASTEXITCODE; $value=$raw | ConvertFrom-Json
        Check ($value.ok -eq [bool]$success -and $code -eq (1-$success)) 'JSON and process exit disagree.'
    }
    Import-Module (Join-Path $frameworkRoot 'Framework\AutomatedGuiTestingAgentFramework.psm1') -Force
    $api=Invoke-AGTAPotatoJson -PotatoCliPath $cliPath -Command hotkey -Arguments @('-Keys','^s') -RunRoot $testRoot
    Check (-not $api.ok -and $api.error.type -eq 'InteractionPolicyViolation') 'API exploration bypassed default policy.'
    $valid=$final | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    Check (Test-AGTAGeneratedResult $valid) 'Valid policy/assertion result rejected.'
    $valid.interactionPolicy.compliant=$false
    Check (-not (Test-AGTAGeneratedResult $valid)) 'API accepted false compliance.'
    $valid.interactionPolicy.compliant=$true; $valid.steps[0].assertions=@()
    Check (-not (Test-AGTAGeneratedResult $valid)) 'API accepted assertion-free PASS.'

    # Exercise cleanup state handling without sending any desktop command.
    $ctx=Initialize-AGTAGeneratedTest -PotatoCliPath $cliPath -TestCaseCsv $csv -RunRoot $testRoot
    Register-OpenedProcess -StartResult ([pscustomobject]@{ok=$true;data=@{ownedProcessId=$PID}})
    $arguments=@(Resolve-AGTACommandArguments start @('-ProcessName','fixture.exe'))
    Check ($arguments[-2] -eq '-RequireNewWindow' -and $arguments[-1] -eq 'true') 'Framework still requires a new shell process.'
    Check ((@(Resolve-AGTACommandArguments start $arguments) -join '|') -eq ($arguments -join '|')) 'Ownership defaults are not idempotent in receipts.'
    $disabled=$false
    try {Resolve-AGTACommandArguments start @('-RequireNewWindow','false') | Out-Null} catch {$disabled=$true}
    Check $disabled 'Framework launch ownership was silently disabled.'
    Register-OpenedProcess -StartResult ([pscustomobject]@{ok=$true;data=@{ownedProcessId=2147483647}})
    Check ($script:AGTAOpenedProcessNames.Count -eq 1) 'An exited launcher threw or registered an unrelated owner.'
    $script:remaining=1
    $script:closeArgs=@()
    function Invoke-PotatoJson {
        param($Command,$Arguments)
        if ($Command -eq 'close-window') { $script:closeArgs=$Arguments }
        if ($Command -eq 'click') { $script:clickArgs=$Arguments; return [pscustomobject]@{ok=$true;command='click';data=@{clicked=$true}} }
        [pscustomobject]@{ok=$true;data=@{count=$script:remaining;elements=@()}}
    }
    $clickCommands=@()
    $clickResult=Invoke-StepClick -Commands ([ref]$clickCommands) -Arguments @('-Name','Fixture')
    Check ($clickResult.data.clicked -and $script:clickArgs[-2] -eq '-Method' -and $script:clickArgs[-1] -eq 'Auto' -and $clickCommands.Count -eq 1) 'Step click did not default to Auto and record the action.'
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 0 -PromptTimeoutMs 0)
    Check (@($cleanup | Where-Object { $_.ok -eq $false }).Count -eq 1) 'Remaining owned window was silently accepted.'
    Check (@($cleanup | Where-Object {$_.action -eq 'preserve-potato-state'}).Count -eq 1 -and @($cleanup | Where-Object {$_.action -eq 'clear-potato-state'}).Count -eq 0) 'Failed cleanup erased its recovery context.'
    Check ($script:closeArgs[0] -eq '-ProcessId' -and $script:closeArgs[1] -eq "$PID") 'Cleanup used broad process-name targeting.'
    $script:remaining=0
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 0 -PromptTimeoutMs 0)
    Check (@($cleanup | Where-Object { $_.ok -eq $false }).Count -eq 0) 'Clean ownership cleanup failed.'
    $savedProcesses=$script:AGTAOpenedProcessNames
    $script:AGTAOpenedProcessNames=@()
    $script:AGTAOpenedWindows=@(@{nativeWindowHandle=123;processId=456;processStartTime='789';className='Fixture'})
    $script:remaining=1
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 0)
    Check (@($cleanup | Where-Object {$_.action -eq 'close-owned-window' -and -not $_.ok}).Count -eq 1) 'Window cleanup hid a pending prompt.'
    Check ($script:closeArgs[0] -eq '-WindowIdentityJson' -and @($cleanup | Where-Object {$_.action -eq 'preserve-potato-state'}).Count -eq 1) 'Shared-host cleanup used a process selector or erased recovery state.'
    $script:remaining=0
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 0)
    Check (@($cleanup | Where-Object {-not $_.ok}).Count -eq 0) 'Closed window required shared-process exit.'
    $script:AGTAOpenedWindows=@();$script:AGTAOpenedProcessNames=$savedProcesses
    # Exit between a window snapshot and the next owner check must not report
    # the stale snapshot as a cleanup failure or target a reused PID.
    $script:remaining=1; $script:ownerChecks=0
    function Get-Process {
        param($Id)
        $script:ownerChecks++
        if ($script:ownerChecks -eq 1) { Microsoft.PowerShell.Management\Get-Process -Id $Id }
    }
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 500 -PromptTimeoutMs 0)
    Check (@($cleanup | Where-Object {$_.ok -eq $false}).Count -eq 0 -and @($cleanup | Where-Object {$_.action -eq 'clear-potato-state'}).Count -eq 1) 'Exited owner was reported as still open from a stale window snapshot.'
    $script:ownerChecks=0
    function Get-Process {
        param($Id)
        $script:ownerChecks++
        $live=Microsoft.PowerShell.Management\Get-Process -Id $Id
        if ($script:ownerChecks -eq 1) { return $live }
        [pscustomobject]@{Id=$Id;StartTime=$live.StartTime.AddSeconds(1)}
    }
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 0 -PromptTimeoutMs 0)
    Check (@($cleanup | Where-Object {$_.ok -eq $false}).Count -eq 0 -and $script:ownerChecks -eq 2) 'Reused PID was treated as the original owned process at the deadline.'
    # Plan orchestration must stop dependent GUI bodies while retaining coverage,
    # assertions, cleanup, and a truthful failing result.
    $ctx.Steps=@($ctx.Steps[0],$ctx.Steps[0])
    $script:planCleanup=0; $script:dependentRan=$false
    function Invoke-TestCleanup { $script:planCleanup++; [pscustomobject]@{action='fixture';ok=$true} }
    $badPlan=Invoke-AGTATestPlan -StepBodies @({param($Commands,$Evidence) Assert-ExpectedResult $false 'Expected failure'}, {param($Commands,$Evidence) $script:dependentRan=$true; Assert-ExpectedResult $true 'Must not run'}) -PassThru
    Check (-not $badPlan.ok -and $badPlan.summary.failed -eq 1 -and $badPlan.summary.skipped -eq 1 -and -not $script:dependentRan -and $script:planCleanup -eq 1 -and $badPlan.coverageOk) 'Plan lost fail-stop/cleanup/coverage semantics.'
    $caught=$false
    try { Invoke-AGTATestPlan -StepBodies @({throw 'Must not execute'}) -PassThru } catch { $caught=$_.Exception.Message -like 'Test plan must contain*' }
    Check ($caught -and $script:planCleanup -eq 1) 'Incomplete plan reached execution.'
    $goodPlan=Invoke-AGTATestPlan -StepBodies @({param($Commands,$Evidence) Assert-ExpectedResult $true 'First'}, {param($Commands,$Evidence) Assert-ExpectedResult $true 'Second'}) -PassThru
    Check ($goodPlan.ok -and $goodPlan.summary.passed -eq 2 -and $script:planCleanup -eq 2 -and (Get-AGTATestExitCode) -eq 0) 'Passing plan did not retain existing result/exit contract.'
    "Runtime checks: $script:checks passed"
}
finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-regression-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
