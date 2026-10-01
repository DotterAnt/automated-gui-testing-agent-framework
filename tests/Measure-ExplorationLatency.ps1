param([ValidateRange(3,30)] [int]$Count=6,[string]$OutFile)
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\Exploration.ps1')
. (Join-Path $frameworkRoot 'Framework\ExplorationHost.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-latency-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$run=Join-Path $root 'run'
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Read-only state' | Set-Content -LiteralPath $csv
    $source=Join-Path (Split-Path $frameworkRoot) 'potato-cli'
    $cliRoot=Join-Path $root 'cli';[void][IO.Directory]::CreateDirectory($cliRoot)
    Copy-Item -LiteralPath (Join-Path $source 'PoTAToCli') -Destination $cliRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $source 'potato.ps1'),(Join-Path $source 'commands.json') -Destination $cliRoot
    $cli=Join-Path $cliRoot 'potato.ps1'
    Initialize-AGTAExploration $run $csv GuiNavigation $cli | Out-Null
    $entry=Join-Path $frameworkRoot 'Invoke-Exploration.ps1'
    $request='[{"stepIndex":1,"command":"state","arguments":[]}]'
    # Warm the same worker/backend before both measured paths.
    $warm=& $entry -Action Batch -RunRoot $run -RequestsJson $request | ConvertFrom-Json
    if (-not $warm.ok) {throw 'Warm-up failed.'}
    $oldEncoding=$OutputEncoding
    $encodingWatch=[Diagnostics.Stopwatch]::StartNew()
    $OutputEncoding=New-Object Text.UTF8Encoding($false)
    $encodingMs=$encodingWatch.Elapsed.TotalMilliseconds
    $samples=@()
    $callerExe=Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') {'pwsh.exe'} else {'powershell.exe'})
    # EncodedCommand preserves paths/JSON without native argument quoting. Only
    # generated literals below enter the fresh shell; no supplied code executes.
    $literalEntry="'"+$entry.Replace("'","''")+"'"
    $literalRun="'"+$run.Replace("'","''")+"'"
    $literalRequest="'"+$request.Replace("'","''")+"'"
    try {
        for ($i=0;$i -lt $Count;$i++) {
            # Alternate order to reduce warm-up/order bias. Both dispatch the
            # same command to the same host and write actual receipts.
            $modes=if ($i%2) {@('FreshShellDirect','FreshShellNativePipe','Direct','NativePipe')} else {@('NativePipe','Direct','FreshShellNativePipe','FreshShellDirect')}
            foreach ($mode in $modes) {
                $watch=[Diagnostics.Stopwatch]::StartNew()
                if ($mode -eq 'Direct') {
                    $raw=& $entry -Action Batch -RunRoot $run -RequestsJson $request
                } elseif ($mode -eq 'NativePipe') {
                    $raw=$request | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Batch -RunRoot $run -RequestsStdin
                } else {
                    $code=if ($mode -eq 'FreshShellDirect') {
                        "& $literalEntry -Action Batch -RunRoot $literalRun -RequestsJson $literalRequest"
                    } else {
                        '$OutputEncoding=New-Object Text.UTF8Encoding($false); '+
                        "$literalRequest | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $literalEntry -Action Batch -RunRoot $literalRun -RequestsStdin"
                    }
                    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
                    $info=[Diagnostics.ProcessStartInfo]::new()
                    $info.FileName=$callerExe
                    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
                    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
                    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
                    $info.StandardOutputEncoding=[Text.Encoding]::UTF8
                    $process=[Diagnostics.Process]::Start($info)
                    try {
                        $errors=$process.StandardError.ReadToEndAsync()
                        $raw=$process.StandardOutput.ReadToEnd()
                        $process.WaitForExit()
                        if ($process.ExitCode -ne 0) {throw "Fresh shell failed: $($errors.GetAwaiter().GetResult())"}
                    } finally {$process.Dispose()}
                }
                $wallMs=$watch.Elapsed.TotalMilliseconds
                $result=$raw | ConvertFrom-Json
                if ($LASTEXITCODE -ne 0 -or -not $result.ok -or -not $result.explorationCommandId) {throw "Failed $mode request"}
                $samples+=,[ordered]@{mode=$mode;wallMs=[Math]::Round($wallMs,2);
                    clientMs=$result.explorationTiming.clientMs;hostMs=$result.explorationTiming.hostMs;
                    cliTotalMs=$result.totalDurationMs;cliBackendMs=$result.durationMs}
            }
        }
    } finally {$OutputEncoding=$oldEncoding}
    $result=@{count=$Count;encodingAssignmentMs=[Math]::Round($encodingMs,3);powershell=$PSVersionTable.PSVersion.ToString();samples=$samples;
        note='Warm worker, read-only state requests and identical receipts. Direct/NativePipe use the existing caller; FreshShell variants include a new matching caller process with NoProfile. NativePipe variants add another powershell.exe process. Excludes external shell-tool/model time.'}
    if ($OutFile) {$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8}
    $result | ConvertTo-Json -Depth 8 -Compress
} finally {
    Invoke-AGTAExplorationHost $run @{} -Stop | Out-Null
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-latency-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
