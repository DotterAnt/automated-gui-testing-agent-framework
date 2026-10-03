param([int]$ParentId)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# The input pipe closes with the parent, except when UIA is stuck inside a call.
# A separate native thread covers that case without relying on PS event pumping.
Add-Type -Path (Join-Path $PSScriptRoot 'Framework\ProcessLifetime.cs')
[AGTAProcessLifetime]::WatchParent($ParentId)
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
