[CmdletBinding()]
param([string] $Name, [string] $Names)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Framework\GeneratedScriptRuntime.ps1')
if ($Name -and $Names) { throw 'Use Name or comma-separated Names, not both.' }
if ($Names) { @(foreach ($item in ($Names -split ',')) { Get-AGTARuntimeHelp -Name $item.Trim() }) | ConvertTo-Json -Depth 5 -Compress }
else { @(Get-AGTARuntimeHelp -Name $Name) | ConvertTo-Json -Depth 5 -Compress }
