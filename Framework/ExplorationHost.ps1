# Local, current-user-only request transport for tools without interactive stdin.
function Get-AGTAExplorationPipeName {
    param([string]$RunRoot)
    $root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    $hash=[Security.Cryptography.SHA256]::Create()
    try {$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$PSScriptRoot|$identity|$session|$root".ToUpperInvariant()))).Replace('-','')}
    finally {$hash.Dispose()}
    'agta-exploration-'+$key
}

function Connect-AGTAExplorationPipe {
    param([string]$Name,[int]$TimeoutMs)
    $options=[IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $Name, [IO.Pipes.PipeDirection]::InOut, $options)
    try {$pipe.Connect($TimeoutMs);return $pipe} catch {$pipe.Dispose();throw}
}

function Invoke-AGTAExplorationHost {
    param([string]$RunRoot,[hashtable]$Parameters,[switch]$Stop,
        [ValidateRange(1,3600)] [int]$IdleSeconds=300)
    $connectWatch=[Diagnostics.Stopwatch]::StartNew()
    $hostStarted=$false
    $name=Get-AGTAExplorationPipeName $RunRoot
    $pipe=$null
    try {$pipe=Connect-AGTAExplorationPipe $name 150} catch [TimeoutException] {}
    if (-not $pipe -and $Stop) {return @{responses=@('{"ok":true,"hostStopped":false}');exitCode=0}}
    if (-not $pipe) {
        $mutex=[Threading.Mutex]::new($false,('Local\'+$name+'-startup'))
        $locked=$false
        try {
            try {$locked=$mutex.WaitOne(10000)} catch [Threading.AbandonedMutexException] {$locked=$true}
            if (-not $locked) {throw 'Exploration host startup is busy. No request was sent.'}
            try {$pipe=Connect-AGTAExplorationPipe $name 150} catch [TimeoutException] {}
            if (-not $pipe) {
                $worker=Join-Path (Split-Path $PSScriptRoot) 'Invoke-ExplorationHost.ps1'
                $token=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RunRoot))
                $child=Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory (Split-Path $PSScriptRoot) -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$worker+'"'),'-RunRootToken',$token,'-IdleSeconds',"$IdleSeconds")
                $hostStarted=$true
                try {$pipe=Connect-AGTAExplorationPipe $name 10000}
                catch {if (-not $child.HasExited) {Stop-Process -Id $child.Id -ErrorAction SilentlyContinue};throw 'Exploration host did not start. No request was sent; use Transport InProcess to diagnose.'}
            }
        } finally {if ($locked) {$mutex.ReleaseMutex()};$mutex.Dispose()}
    }
    $connectMs=[Math]::Round($connectWatch.Elapsed.TotalMilliseconds,2)
    $reader=$null;$writer=$null;$sent=$false
    try {
        $encoding=[Text.UTF8Encoding]::new($false)
        $reader=[IO.StreamReader]::new($pipe,$encoding,$false,4096,$true)
        $writer=[IO.StreamWriter]::new($pipe,$encoding,4096,$true);$writer.AutoFlush=$true
        $request=if ($Stop) {@{stop=$true}} else {@{parameters=$Parameters}}
        # A lost response after this boundary must never replay the request.
        $sent=$true
        $writer.WriteLine((ConvertTo-Json -InputObject $request -Depth 50 -Compress))
        $pending=$reader.ReadLineAsync()
        if (-not $pending.Wait(180000)) {throw 'Exploration host response timed out.'}
        $line=$pending.GetAwaiter().GetResult()
        if (-not $line) {throw 'Exploration host closed without a response.'}
        $response=$line | ConvertFrom-Json
        $response | Add-Member -NotePropertyName connectMs -NotePropertyValue $connectMs -Force
        $response | Add-Member -NotePropertyName hostStarted -NotePropertyValue $hostStarted -Force
        $response
    } catch {
        $outcome=if ($sent) {'unknown'} else {'not-dispatched'}
        @{responses=@((@{ok=$false;outcome=$outcome;error=$_.Exception.Message;
            next='Inspect actual GUI state and Status before retrying a request whose outcome is unknown.'} | ConvertTo-Json -Compress));exitCode=1}
    } finally {if ($writer) {$writer.Dispose()};if ($reader) {$reader.Dispose()};$pipe.Dispose()}
}
