param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-efficiency-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Check($condition,$message) {if (-not $condition) {throw $message};$script:checks++}
function Reject([scriptblock]$body,$message) {$failure=$null;try {& $body | Out-Null} catch {$failure=$_};Check ([bool]$failure) $message;return $failure}
try {
    $guard=[ordered]@{Name='Observed dialog';ClassName='#32770';ProcessId=123}
    $values=@(Resolve-AGTACommandArguments click @('-WindowSelectorJson',$guard,'-Name','Submit'))
    $parsed=$values[1] | ConvertFrom-Json
    Check ($parsed.Name -eq 'Observed dialog' -and $parsed.ProcessId -eq 123 -and $values[3] -eq 'Submit') 'Structured guard was cast to OrderedDictionary text.'
    $values=@(Resolve-AGTACommandArguments observe @('-PathJson',@(@{Name='Container'},@{AutomationId='Field'})))
    Check (($values[1] | ConvertFrom-Json).Count -eq 2) 'Structured selector path lost its array.'
    $values=@(Resolve-AGTACommandArguments observe @('-PathJson',@(@{Name='Container'})))
    Check ($values[1].StartsWith('[') -and $values[1].EndsWith(']')) 'One-entry selector path lost its JSON array shape.'
    Reject {Resolve-AGTACommandArguments type @('-Text',$guard)} 'Unexpected structured text was silently stringified.' | Out-Null
    Reject {Resolve-AGTACommandArguments click @('-Name',$null)} 'Null selector was silently accepted.' | Out-Null
    $zip=Join-Path $root 'fixture.zip'
    Add-Type -AssemblyName System.IO.Compression
    $stream=[IO.File]::Open($zip,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        foreach ($name in @('content/part1.xml','content/part2.xml','other.xml')) {
            $entry=$archive.CreateEntry($name)
            $writer=New-Object IO.StreamWriter($entry.Open(),[Text.UTF8Encoding]::new($false))
            try {$writer.Write('<text>Test '+[char]0x151+'</text>')} finally {$writer.Dispose()}
        }
    } finally {$archive.Dispose();$stream.Dispose()}
    # Writer holding the file is the common archive verification failure.
    $held=[IO.File]::Open($zip,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    try {$entries=@(Read-AGTAZipText $zip -EntryPattern 'content/*.xml' -TimeoutMs 0)} finally {$held.Dispose()}
    Check ($entries.Count -eq 2 -and $entries[0].text.Contains([string][char]0x151)) 'Shared ZIP text verification lost entries or Unicode.'
    Reject {Read-AGTAZipText $zip -EntryPattern '*.xml' -MaxBytes 10 -TimeoutMs 1000} 'Archive byte limit was bypassed.' | Out-Null
    Reject {Read-AGTAZipText $zip -EntryPattern 'missing.xml' -TimeoutMs 0} 'Missing archive entry pretended to verify content.' | Out-Null
    $invalid=Join-Path $root 'invalid.zip'
    [IO.File]::WriteAllText($invalid,'invalid content')
    Reject {Read-AGTAZipText $invalid -EntryPattern '*' -TimeoutMs 0} 'Corrupt archive was accepted.' | Out-Null
    $source=Join-Path $root 'preflight.ps1'
    foreach ($code in @('$home = 1','$script:HOME = 1','Read-AGTAArtifactBytes -Path x -Count 10485760','Read-AGTAArtifactBytes -Path x -Count:0')) {
        $code | Set-Content -LiteralPath $source
        Check (-not (Test-AGTAGeneratedScript $source).ok) "Preflight accepted recorded failure: $code"
    }
    '$taskHome = 1; $null = Get-Date; Read-AGTAArtifactBytes -Path x -Count "4096"; Read-AGTAZipText -Path x -EntryPattern "content/*.xml"' | Set-Content -LiteralPath $source
    Check (Test-AGTAGeneratedScript $source).ok 'Generic archive verification failed preflight.'
    $full=@{ok=$false;summary=@{total=2;passed=1;failed=1};cleanupOk=$true;artifacts=@{resultPath='full.json'};
        steps=@(@{stepIndex=1;status='PASS';commands=@(@{ok=$true;arguments=@('verbose')})},
        @{stepIndex=2;status='FAIL';error='Original failure';evidence=@('failure.png');commands=@(@{ok=$false;error='ScopeNotReady';arguments=@('-WindowSelectorJson','{}')})})}
    $compact=ConvertTo-AGTACompactTestResult $full
    Check ($compact.summary.passed -eq 1 -and $compact.steps[1].failedCommands[0].error -eq 'ScopeNotReady' -and $compact.steps[1].evidence[0] -eq 'failure.png' -and $compact.artifacts.resultPath -eq 'full.json') 'Compact output lost actionable failure or evidence paths.'
    Check ($compact.steps[0].failedCommands.Count -eq 0 -and -not $compact.steps[0].Contains('commands')) 'Compact output repeated successful command transcripts.'
    $help=Get-AGTARuntimeHelp Read-AGTAZipText
    Check ($help.available -and $help.syntax -match 'EntryPattern') 'Generic ZIP reader is missing from targeted help.'
    $help=Get-AGTARuntimeHelp Read-AGTAArtifactBytes
    Check ($help.parameterConstraints.Count.maximum -eq 1048576 -and $help.note -match 'exact byte count') 'Artifact help hid exact-length semantics or validation bounds.'
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Observed fixture' | Set-Content -LiteralPath $csv
    $cli=Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1'
    $run=Join-Path $root 'stream'
    Initialize-AGTAExploration $run $csv GuiNavigation $cli | Out-Null
    $lines=@(
        '{"action":"Batch","requests":[{"stepIndex":1,"command":"help","arguments":["-Topic","type"]},{"stepIndex":1,"command":"help","arguments":["-Topic","click"]}]}',
        '{"action":"Status"}',
        '{"action":"Quit"}'
    )
    $responses=@($lines | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Invoke-ExplorationStream.ps1') -RunRoot $run | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 0 -and $responses.Count -eq 4 -and $responses[0].explorationCommandId -and $responses[1].explorationCommandId -and $responses[2].commandCount -eq 2) "Persistent exploration lost responses or receipts: $($responses.Count) responses, exit $LASTEXITCODE."
    Check (-not $responses[0].workflow -and $responses[1].workflow -and $responses[2].workflow) 'Batch repeated workflow or omitted it at its final observation.'
    $stopped=Join-Path $root 'stopped'
    Initialize-AGTAExploration $stopped $csv GuiNavigation $cli | Out-Null
    $responses=@(@('{"action":"Batch","requests":[{"stepIndex":1,"command":"help","arguments":["-Topic","missing"]}]}','{"action":"Status"}') | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Invoke-ExplorationStream.ps1') -RunRoot $stopped | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 1 -and $responses.Count -eq 1 -and -not $responses[0].ok -and $responses[0].workflow) 'Persistent exploration continued queued actions after failure.'
    $responses=@('{"action":"Batch","requests":[]}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $frameworkRoot 'Invoke-ExplorationStream.ps1') -RunRoot $stopped | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($LASTEXITCODE -eq 1 -and $responses.Count -eq 1 -and $responses[0].outcome -eq 'not-dispatched') 'Malformed stream request hid its failure.'
    "Efficiency checks: $script:checks passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-efficiency-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
