param([int]$ParentId)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# The input pipe closes with the parent, except when UIA is stuck inside a call.
# A separate native thread covers that case without relying on PS event pumping.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
public static class AGTAWorkerLifetime {
    public static void Watch(int id) {
        var parent=Process.GetProcessById(id);long started=parent.StartTime.ToUniversalTime().Ticks;
        var thread=new Thread(delegate() {
            while (true) {
                try {if (parent.HasExited || parent.StartTime.ToUniversalTime().Ticks!=started) Environment.Exit(0);}
                catch {Environment.Exit(0);}
                Thread.Sleep(1000);
            }
        });thread.IsBackground=true;thread.Start();
    }
}
'@
[AGTAWorkerLifetime]::Watch($ParentId)
$module=$null;$loadedPath=$null
while ($null -ne ($line=[Console]::ReadLine())) {
    $request=$null
    try {
        $request=$line | ConvertFrom-Json
        if (-not $module -or $loadedPath -cne $request.cliPath) {
            $loadedPath=$request.cliPath
            $module=Import-Module (Join-Path (Split-Path $loadedPath) 'PoTAToCli\PoTAToCli.psm1') -PassThru -ErrorAction Stop
        }
        $result=& $module {param($cmd,$values,$root) Invoke-PotatoCliCommand -Command $cmd -Arguments $values -CliRoot $root -AsObject} $request.command @($request.arguments) (Split-Path $loadedPath)
    } catch {$result=@{ok=$false;command=$request.command;data=$null;outcome='unknown';error=@{type='WorkerError';message=$_.Exception.Message}}}
    [Console]::WriteLine(($result | ConvertTo-Json -Depth 80 -Compress))
}
