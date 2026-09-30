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
    $help=Invoke-PotatoJson help @('-Topic','type')
    Check ($help.ok -and $ctx.Timing.commandCount -eq 1) 'In-process transport/timing failed.'
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
    $final=Complete-AGTAGeneratedTest @($pass) @(@{ok=$false;error='cleanup fixture'}) -PassThru
    Check (-not $final.ok -and (Get-AGTATestExitCode) -eq 1) 'Cleanup failure passed.'
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
    Check ($script:closeArgs[0] -eq '-ProcessId' -and $script:closeArgs[1] -eq "$PID") 'Cleanup used broad process-name targeting.'
    $script:remaining=0
    $cleanup=@(Invoke-TestCleanup -CloseTimeoutMs 0 -PromptTimeoutMs 0)
    Check (@($cleanup | Where-Object { $_.ok -eq $false }).Count -eq 0) 'Clean ownership cleanup failed.'
    "Runtime checks: $script:checks passed"
}
finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-regression-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
