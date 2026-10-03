param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'Framework\CliWorker.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-cli-worker-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
try {
    $cli=Join-Path $root 'potato.ps1'
    $moduleDir=Join-Path $root 'PoTAToCli';[void][IO.Directory]::CreateDirectory($moduleDir)
    '# Inert fixture entrypoint' | Set-Content $cli
    @'
function Invoke-PotatoCliCommand {
    param($Command,$Arguments,$CliRoot,[switch]$AsObject)
    if ($Command -eq 'hang') {
        [Threading.Thread]::Sleep(5000)
        [IO.File]::WriteAllText($Arguments[0],'Late action must never run')
    }
    @{ok=$true;command=$Command;data=@{pid=$PID;text=($Arguments -join '|')};durationMs=1}
}
Export-ModuleMember -Function Invoke-PotatoCliCommand
'@ | Set-Content (Join-Path $moduleDir 'PoTAToCli.psm1')
    $first=Invoke-AGTAIsolatedCliCommand $cli state @('literal '+[char]0x151) $root
    Check ($first.ok -and $first.data.text -ceq ('literal '+[char]0x151)) ('Worker startup/framing corrupted a literal Unicode argument: '+($first | ConvertTo-Json -Depth 8 -Compress))
    $times=@(foreach ($i in 1..6) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $value=Invoke-AGTAIsolatedCliCommand $cli state @() $root
        Check ($value.ok -and $value.data.pid -eq $first.data.pid) 'Fast calls spawned a new process instead of retaining the worker.'
        $watch.ElapsedMilliseconds
    })
    $marker=Join-Path $root 'late-action.txt'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $failed=Invoke-AGTAIsolatedCliCommand $cli hang @($marker) $root -DeadlineMs 200
    Check (-not $failed.ok -and $failed.error.type -eq 'ProviderTimeout' -and $failed.outcome -eq 'unknown' -and $watch.ElapsedMilliseconds -lt 3000) 'Uninterruptible provider call did not return a bounded unknown-outcome failure.'
    $active=Get-Content (Join-Path $root 'logs\active-provider-command.json') -Raw | ConvertFrom-Json
    Check ($active.state -eq 'TimedOut' -and $active.command -eq 'hang' -and $active.providerPid -eq $first.data.pid) 'Timeout lost the last dispatched command/progress record.'
    Check (-not (Get-Process -Id $first.data.pid -ErrorAction SilentlyContinue) -and -not (Test-Path $marker)) 'Timed-out worker survived or executed its delayed mutation.'
    $healthy=Invoke-AGTAIsolatedCliCommand $cli state @('recovered') $root
    Check ($healthy.ok -and $healthy.data.pid -ne $first.data.pid -and -not (Test-Path $marker)) 'Recovery could not create a healthy worker or automatically retried the failed command.'
    Check ((Get-AGTACliCommandDeadline @('-TimeoutMs','60000')) -eq 65000 -and (Get-AGTACliCommandDeadline @()) -eq 30000) 'Provider deadline ignored a legitimate bounded wait.'
    Check ((Get-AGTACliCommandDeadline @('-TimeoutMs=60000')) -eq 65000 -and (Get-AGTACliCommandDeadline @('-TimeoutMs')) -eq 30000) 'Provider deadline ignored an equals-form wait or mishandled a missing value.'
    'CLI worker: '+$checks+' checks passed; retained state calls median '+(@($times | Sort-Object)[3])+'ms.'
} finally {
    foreach ($worker in $script:AGTACliWorkers.Values) {Stop-AGTACliWorker $worker}
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-cli-worker-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
