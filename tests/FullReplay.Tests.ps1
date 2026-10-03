param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $frameworkRoot 'Framework\CommandHistory.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-full-replay-'+[guid]::NewGuid().ToString('N'))
$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
function Run-SavedFixture {
    $hostPath=(Get-Process -Id $PID).Path
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$hostPath
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$saved+'" -PotatoCliPath "'+$cli+'" -TestCaseCsv "'+$csv+'" -RunRoot "'+$run+'" -FrameworkRoot "'+$frameworkRoot+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {throw 'Saved fixture exceeded its noninteractive test deadline.'}
        Check ($process.ExitCode -eq 0 -or $process.ExitCode -eq 1) ('Unexpected process failure: '+$errors.GetAwaiter().GetResult())
        $result=$output.GetAwaiter().GetResult().Trim() | ConvertFrom-Json
        Check (($process.ExitCode -eq 0) -eq [bool]$result.ok) 'Saved driver exit code disagreed with its full result.'
        return $result
    } finally {
        if (-not $process.HasExited) {$process.Kill();[void]$process.WaitForExit(2000)}
        $process.Dispose()
    }
}
try {
    $moduleRoot=Join-Path $root 'cli\PoTAToCli';[void][IO.Directory]::CreateDirectory($moduleRoot)
    $cli=Join-Path $root 'cli\potato.ps1';'# Inert fixture entrypoint' | Set-Content $cli
    # Synthetic producer stands in for a GUI export. Only this test fixture
    # writes output; the generated script uses receipt assertions exclusively.
    @'
function Invoke-PotatoCliCommand {
    param($Command,$Arguments,$CliRoot,[switch]$AsObject)
    $data=@{}
    switch ($Command) {
        fixture-output {
            $path=$Arguments[1]
            [IO.File]::WriteAllText($path,'Fixture without extractable PDF text')
            $data=@{path=$path}
        }
        wait-file {
            $file=Get-Item -LiteralPath $Arguments[1] -ErrorAction SilentlyContinue
            $data=@{path=$Arguments[1];exists=[bool]$file;conditionMet=[bool]$file;
                creationTimeUtc=$file.CreationTimeUtc.ToString('o');lastWriteTimeUtc=$file.LastWriteTimeUtc.ToString('o')}
        }
        state {$data=@{fixture=$true}}
        default {throw ('Unexpected command, including forbidden extra PDF inspection: '+$Command)}
    }
    [pscustomobject]@{ok=$true;command=$Command;data=$data;durationMs=1}
}
'@ | Set-Content (Join-Path $moduleRoot 'PoTAToCli.psm1')
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Create output,,Export action succeeded','Print image to PDF,,PDF exists','Finish,,Fixture verified' | Set-Content $csv
    $run=Join-Path $root 'run'
    Initialize-AGTAExploration $run $csv GuiNavigation -PotatoCliPath $cli | Out-Null
    foreach ($index in 1..3) {
        Add-AGTAExplorationCommand $run $index click @() @{ok=$true} | Out-Null
        $receipt=Add-AGTAExplorationCommand $run $index wait-file @() @{ok=$true;data=@{conditionMet=$true}}
        Complete-AGTAExplorationStep $run $index 'Synthetic observed fixture' 'CSV expectation verified' $receipt | Out-Null
    }
    Complete-AGTAExploration $run $csv GuiNavigation | Out-Null
    # Legacy metadata must not require the removed live session/hash gate.
    $manifestPath=Join-Path $run 'logs\exploration.json'
    $manifest=Get-Content $manifestPath -Raw | ConvertFrom-Json
    $manifest | Add-Member workflowMode Live
    $manifest | ConvertTo-Json -Depth 30 | Set-Content $manifestPath
    $reference=Get-Content (Join-Path $run 'logs\replay-reference.json') -Raw | ConvertFrom-Json
    Check (($reference.replayRules -join ' ') -match 'PDF existence only' -and ($reference.replayRules -join ' ') -notmatch 'Step/Verify|Repair|Skip|Close after') 'Replay reference retained diagnostic workflow or mandatory PDF content checks.'
    $template=[IO.File]::ReadAllText((Join-Path $frameworkRoot 'templates\GeneratedScript.Template.ps1'))
    $prefix=$template.Substring(0,$template.IndexOf('$StepBodies = @('))
    $source=$prefix+@'
$OutputPath=Join-Path $Context.ExecutionEvidenceRoot 'image.pdf'
$State.calls=0
$StepBodies=@(
    {param([ref]$Commands,[ref]$Evidence)
        $State.calls++
        Invoke-StepCommand $Commands fixture-output @('-Path',$OutputPath) | Assert-PotatoOk
        Assert-ExpectedResult -Condition ($State.calls -eq 1) -Message 'Producer executed exactly once'
    },
    {param([ref]$Commands,[ref]$Evidence)
        Invoke-StepCommand $Commands wait-file @('-Path',$OutputPath) | Assert-FileWait -Message 'PDF exists'
    },
    {param([ref]$Commands,[ref]$Evidence)
        $ready=Invoke-StepCommand $Commands state @()
        Assert-PotatoOk $ready
        Assert-ExpectedResult -Condition ([bool]$ready.data.fixture) -Message 'Fixture verified'
    }
)
Invoke-AGTATestPlan -StepBodies $StepBodies -OutputMode $OutputMode
exit (Get-AGTATestExitCode)
'@
    $saved=Join-Path $root 'Saved.Generated.ps1';$source | Set-Content $saved
    $audit=Test-AGTAGeneratedScript -ScriptPath $saved -TestCaseCsv $csv -PotatoCliPath $cli -ExplorationPath $manifestPath
    Check $audit.ok ('Existence-only saved replay failed preflight: '+($audit.issues -join '; '))
    Check (-not (Get-Command Initialize-AGTAGeneratedTest).Parameters.ContainsKey('RunKind') -and -not (Get-Command Test-AGTAGeneratedScript).Parameters.ContainsKey('AllowIncompleteExploration')) 'Diagnostic runtime entrypoints remained available.'
    $success=Run-SavedFixture
    Check ($success.ok -and $success.qualifying -and $success.runKind -eq 'Replay' -and $success.summary.passed -eq 3 -and $success.cleanupOk) ('First full execution did not qualify: '+($success.summary.failedSteps | ConvertTo-Json -Depth 5 -Compress))
    Check (@(Get-ChildItem (Join-Path $run 'results') -Filter 'replay-*.json').Count -eq 1 -and @(Get-ChildItem (Join-Path $run 'results') -Filter 'diagnostic-*.json').Count -eq 0) 'First full success created extra attempts or diagnostic artifacts.'
    $commands=@(Get-Content $success.artifacts.commandLogPath | ForEach-Object {$_ | ConvertFrom-Json})
    Check (@($commands | Where-Object {$_.command -eq 'fixture-output'}).Count -eq 1 -and @($commands | Where-Object {$_.command -in @('read-pdf','screenshot')}).Count -eq 0) 'Existence-only execution repeated output or added content inspection.'
    $bounded=@(Get-AGTACommandDiagnostics $success.artifacts.commandLogPath -Last 1 -StepIndex 2)
    Check ($bounded.Count -eq 1 -and $bounded[0].command -eq 'wait-file' -and $bounded[0].data.conditionMet) 'Read-only replay history was lost with diagnostic session removal.'
    $source.Replace('($State.calls -eq 1)','($State.calls -eq 2)') | Set-Content $saved
    $failure=Run-SavedFixture
    Check (-not $failure.ok -and $failure.qualifying -and $failure.steps[0].status -eq 'FAIL' -and $failure.steps[1].status -eq 'SKIPPED' -and $failure.steps[2].status -eq 'SKIPPED' -and $failure.cleanupOk) 'Failure did not stop dependent rows, clean up or remain a recorded full attempt.'
    # A missing receipt must fail instead of entering an interactive host prompt.
    $source.Replace("Invoke-StepCommand `$Commands wait-file @('-Path',`$OutputPath) | Assert-FileWait -Message 'PDF exists'",'Assert-PotatoOk') | Set-Content $saved
    $prompt=Run-SavedFixture
    Check (-not $prompt.ok -and $prompt.steps[0].status -eq 'PASS' -and $prompt.steps[1].status -eq 'FAIL' -and $prompt.steps[1].error -match 'mandatory|NonInteractive|Read and Prompt' -and $prompt.cleanupOk) 'Missing receipt entered a prompt or bypassed fail-stop cleanup.'
    $source | Set-Content $saved
    $fixed=Run-SavedFixture
    Check ($fixed.ok -and $fixed.qualifying -and $fixed.summary.passed -eq 3 -and $fixed.executionId -ne $success.executionId) 'Corrected full replay retained failed live state or skipped its prefix.'
    $archives=@(Get-ChildItem (Join-Path $run 'results') -Filter 'replay-*.json' | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})
    Check ($archives.Count -eq 4 -and @($archives | Where-Object {-not $_.ok -and $_.qualifying}).Count -eq 2) 'Full replay attempt history lost or mislabeled a failure.'
    $manifest.completed=$false;$manifest.completedAt=$null
    $manifest | ConvertTo-Json -Depth 30 | Set-Content $manifestPath
    $audit=Test-AGTAGeneratedScript -ScriptPath $saved -TestCaseCsv $csv -PotatoCliPath $cli -ExplorationPath $manifestPath
    Check (-not $audit.ok -and ($audit.issues -join ' ') -match 'incomplete') 'Full replay allowed incomplete exploration after diagnostic bypass removal.'
    "Full replay checks: $script:checks passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-full-replay-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
