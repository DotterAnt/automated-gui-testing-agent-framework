# A retained process contains synchronous UIA/native calls. The parent can
# terminate only this owned worker if a provider never returns; never the app.
$script:AGTACliWorkers=@{}
function Stop-AGTACliWorker {
    param($Worker)
    if (-not $Worker) {return}
    try {if (-not $Worker.process.HasExited) {$Worker.process.Kill();[void]$Worker.process.WaitForExit(2000)}} catch {}
    $Worker.process.Dispose()
}
function Get-AGTACliCommandDeadline {
    param([object[]]$Arguments)
    $wait=0
    for ($i=0;$i -lt $Arguments.Count;$i++) {
        if ($Arguments[$i] -match '^-(TimeoutMs|MillisecondsToWait|WaitForWindowMs|VerifyTimeoutMs|FocusTimeoutMs)(?:=(\d+))?$') {
            $number=0
            $value=if ($Matches[2]) {$Matches[2]} elseif ($i+1 -lt $Arguments.Count) {[string]$Arguments[$i+1]} else {''}
            if ([int]::TryParse($value,[ref]$number)) {$wait=[Math]::Max($wait,$number)}
        }
    }
    [int][Math]::Min(70000,[Math]::Max(30000,$wait+5000))
}
function Invoke-AGTAIsolatedCliCommand {
    param([string]$PotatoCliPath,[string]$Command,[object[]]$Arguments,[string]$RunRoot,[int]$DeadlineMs=0)
    if (-not $DeadlineMs) {$DeadlineMs=Get-AGTACliCommandDeadline $Arguments}
    if ($DeadlineMs -lt 1 -or $DeadlineMs -gt 70000) {throw 'Provider deadline must be 1..70000 ms.'}
    $key=[IO.Path]::GetFullPath($PotatoCliPath)
    $worker=$script:AGTACliWorkers[$key]
    if ($worker -and $worker.process.HasExited) {Stop-AGTACliWorker $worker;$worker=$null;$script:AGTACliWorkers.Remove($key)}
    if (-not $worker) {
        $entry=Join-Path (Split-Path $PSScriptRoot) 'Invoke-CliWorker.ps1'
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName='powershell.exe'
        $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$entry+'" -ParentId '+$PID
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.Encoding]::UTF8
        $child=[Diagnostics.Process]::Start($info)
        $worker=@{process=$child;errors=$child.StandardError.ReadToEndAsync()}
        $script:AGTACliWorkers[$key]=$worker
    }
    $progressPath=Join-Path $RunRoot 'logs\active-provider-command.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $progressPath))
    $progress=[ordered]@{startedAt=[DateTime]::UtcNow.ToString('o');command=$Command;arguments=$Arguments;providerPid=$worker.process.Id;deadlineMs=$DeadlineMs;state='Pending'}
    $progress | ConvertTo-Json -Depth 30 -Compress | Set-Content -LiteralPath $progressPath -Encoding UTF8
    $sent=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $request=@{cliPath=$key;command=$Command;arguments=$Arguments} | ConvertTo-Json -Depth 30 -Compress
        $sent=$true
        # Redirected StandardInput can use the parent's OEM code page in PS5.
        # Write UTF-8 bytes to the pipe; never change the caller's console.
        $bytes=[Text.Encoding]::UTF8.GetBytes($request+"`n")
        $worker.process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
        $worker.process.StandardInput.BaseStream.Flush()
        $pending=$worker.process.StandardOutput.ReadLineAsync()
        if (-not $pending.Wait($DeadlineMs)) {
            $progress.state='TimedOut'
            Stop-AGTACliWorker $worker;$script:AGTACliWorkers.Remove($key)
            return [pscustomobject]@{ok=$false;command=$Command;data=$null;outcome='unknown';durationMs=$watch.ElapsedMilliseconds;
                error=@{type='ProviderTimeout';message="GUI provider command exceeded ${DeadlineMs}ms. Its owned CLI worker was stopped; application windows were preserved. The action may have occurred. Inspect Status/actual GUI before any further input; no command was retried.";deadlineMs=$DeadlineMs;providerPid=$progress.providerPid}}
        }
        $line=$pending.GetAwaiter().GetResult()
        if (-not $line) {throw 'CLI worker ended without a receipt.'}
        $result=$line | ConvertFrom-Json
        if ($null -eq $result.ok -or $result.command -cne $Command) {throw 'CLI worker returned an invalid receipt.'}
        $progress.state='Returned'
        return $result
    } catch {
        $progress.state='TransportFailed'
        $detail=$_.Exception.Message
        if ($worker.errors.IsCompleted) {
            $workerError=$worker.errors.GetAwaiter().GetResult()
            if ($workerError) {$detail+=' '+$workerError.Substring(0,[Math]::Min(1000,$workerError.Length))}
        }
        Stop-AGTACliWorker $worker;$script:AGTACliWorkers.Remove($key)
        return [pscustomobject]@{ok=$false;command=$Command;data=$null;outcome=$(if ($sent) {'unknown'} else {'not-dispatched'});durationMs=$watch.ElapsedMilliseconds;
            error=@{type='TransportError';message=('CLI worker failed. Inspect actual GUI before retrying; no command was retried. '+$detail)}}
    } finally {
        $progress.finishedAt=[DateTime]::UtcNow.ToString('o')
        $progress | ConvertTo-Json -Depth 30 -Compress | Set-Content -LiteralPath $progressPath -Encoding UTF8
    }
}
