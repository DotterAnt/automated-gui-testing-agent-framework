[CmdletBinding()]
param([Parameter(Mandatory)] [string]$RunRootToken,
    [ValidateRange(1,3600)] [int]$IdleSeconds=300)
$ErrorActionPreference='Stop'
$env:AGTA_PROVIDER_ISOLATION='1'
# Start-Process from PowerShell 7 can inherit its module search order. This
# worker deliberately uses Windows PowerShell; prefer its matching modules.
$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+$env:PSModulePath
$RunRoot=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RunRootToken))
. (Join-Path $PSScriptRoot 'Framework\ExplorationHost.ps1')
$name=Get-AGTAExplorationPipeName $RunRoot
$options=[IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly -bor [IO.Pipes.PipeOptions]::FirstPipeInstance
$pipe=[IO.Pipes.NamedPipeServerStream]::new($name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,$options)
$entry=Join-Path $PSScriptRoot 'Invoke-Exploration.ps1'
try {
    while ($true) {
        $connection=$pipe.WaitForConnectionAsync()
        if (-not $connection.Wait($IdleSeconds*1000)) {break}
        $connection.GetAwaiter().GetResult()
        $reader=$null;$writer=$null;$finish=$false;$dispatched=$false
        try {
            $encoding=[Text.UTF8Encoding]::new($false)
            $reader=[IO.StreamReader]::new($pipe,$encoding,$false,4096,$true)
            $writer=[IO.StreamWriter]::new($pipe,$encoding,4096,$true);$writer.AutoFlush=$true
            $pending=$reader.ReadLineAsync()
            if (-not $pending.Wait(10000)) {throw 'Connected client did not provide a request.'}
            $hostWatch=[Diagnostics.Stopwatch]::StartNew()
            $request=$pending.GetAwaiter().GetResult() | ConvertFrom-Json
            if ($request.stop -eq $true) {
                $response=@{responses=@('{"ok":true,"hostStopped":true}');exitCode=0};$finish=$true
            } else {
                if (-not $request.parameters -or -not [string]::Equals($request.parameters.RunRoot,$RunRoot,[StringComparison]::OrdinalIgnoreCase)) {throw 'Request belongs to another exploration run.'}
                $parameters=@{}
                foreach ($property in $request.parameters.PSObject.Properties) {$parameters[$property.Name]=$property.Value}
                $parameters.Transport='InProcess'
                $global:LASTEXITCODE=0
                $dispatched=$true
                $responses=@(& $entry @parameters)
                $response=@{responses=$responses;exitCode=$LASTEXITCODE;hostProcessId=$PID;
                    hostRequestMs=[Math]::Round($hostWatch.Elapsed.TotalMilliseconds,2)}
                $finish=$parameters.Action -eq 'Complete' -and $LASTEXITCODE -eq 0
            }
            $writer.WriteLine((ConvertTo-Json -InputObject $response -Depth 10 -Compress))
        } catch {
            $outcome=if ($dispatched) {'unknown'} else {'not-dispatched'}
            if ($writer) {try {$writer.WriteLine((@{responses=@((@{ok=$false;outcome=$outcome;error=$_.Exception.Message} | ConvertTo-Json -Compress));exitCode=1} | ConvertTo-Json -Depth 5 -Compress))} catch {}}
        } finally {
            if ($writer) {$writer.Dispose()};if ($reader) {$reader.Dispose()}
            $pipe.Disconnect()
        }
        if ($finish) {break}
    }
} finally {$pipe.Dispose()}
