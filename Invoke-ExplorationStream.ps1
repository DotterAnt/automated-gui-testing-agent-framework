[CmdletBinding()]
param([Parameter(Mandatory)] [string]$RunRoot,
    [ValidateSet('Compact','Full')] [string]$OutputMode='Compact')
$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$entry=Join-Path $PSScriptRoot 'Invoke-Exploration.ps1'
# One long-lived PowerShell host for interactive tools/pipes. The same entrypoint
# validates policy/CSV/receipts on every request; loaded UIA/native types stay warm.
while ($null -ne ($line=[Console]::ReadLine())) {
    try {
        $request=$line.TrimStart([char]0xFEFF) | ConvertFrom-Json
        if (-not $request -or $request -is [array] -or $request.action -notin @('Batch','RecordSteps','Status','Complete','Quit')) {
            throw 'Each line needs action Batch, RecordSteps, Status, Complete or Quit.'
        }
        if ($request.action -eq 'Quit') {
            [Console]::WriteLine('{"ok":true,"action":"Quit"}')
            break
        }
        $parameters=@{Action=$request.action;RunRoot=$RunRoot;OutputMode=$OutputMode;Transport='InProcess'}
        if ($request.action -in @('Batch','RecordSteps')) {
            if (-not $request.requests) {throw 'Batch/RecordSteps needs a nonempty requests array.'}
            $parameters.RequestsJson=ConvertTo-Json -InputObject @($request.requests) -Depth 40 -Compress
        }
        $global:LASTEXITCODE=0
        & $entry @parameters | ForEach-Object {[Console]::WriteLine([string]$_)}
        if ($LASTEXITCODE -ne 0) {exit 1}
        if ($request.action -eq 'Complete') {break}
    }
    catch {
        [Console]::WriteLine((@{ok=$false;error=$_.Exception.Message;outcome='not-dispatched'} | ConvertTo-Json -Compress))
        exit 1
    }
}
