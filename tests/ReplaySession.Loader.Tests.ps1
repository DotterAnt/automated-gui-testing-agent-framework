param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $frameworkRoot 'Framework\ReplaySession.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-loader-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$session=$null
$script:checks=0
function Check($condition,$message) {if (-not $condition) {throw $message};$script:checks++}
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Fixture,,Fixture' | Set-Content $csv
    $cli=Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1'
    Initialize-AGTAExploration $root $csv GuiNavigation $cli | Out-Null
    $template=[IO.File]::ReadAllText((Join-Path $frameworkRoot 'templates\GeneratedScript.Template.ps1'))
    $prefix=$template.Substring(0,$template.IndexOf('$StepBodies = @('))
    $source=$prefix+@'
if (-not $PotatoCliPath) {$PotatoCliPath=Join-Path (Split-Path $FrameworkRoot) 'potato-cli\potato.ps1'}
$State=@{OutputPath=Join-Path $Context.ExecutionEvidenceRoot 'fixture.out';Self=$PSCommandPath;Root=$PSScriptRoot;SystemPath=Join-Path $env:WINDIR 'fixture.input'}
function Get-FixtureEnvironment {
    Join-Path $env:WINDIR 'fixture.input'
}
$StepBodies=@({param([ref]$Commands,[ref]$Evidence)
    Assert-ExpectedResult (-not [string]::IsNullOrWhiteSpace($State.OutputPath)) 'Output path retained'
    Assert-ExpectedResult ((Get-FixtureEnvironment) -eq $State.SystemPath) 'Environment path retained in helper'
})
Invoke-AGTATestPlan -StepBodies $StepBodies -OutputMode $OutputMode
exit (Get-AGTATestExitCode)
'@
    $path=Join-Path $root 'generated.ps1';$source | Set-Content $path
    $session=Import-AGTAPlanSession $root $path
    Check ((& $session.module {$State.OutputPath}) -eq (Join-Path $session.context.ExecutionEvidenceRoot 'fixture.out')) 'Template Context/path setup was not retained.'
    Check ((& $session.module {$State.Self}) -eq $path -and (& $session.module {$State.Root}) -eq $root) 'Parsed setup lost automatic script file/root bindings.'
    Check ((& $session.module {$State.SystemPath}) -eq (Join-Path $env:WINDIR 'fixture.input')) 'Environment path setup did not survive the module loader.'
    $step=Invoke-AGTAPlanStep $session
    Check $step.ok ('Helper lost environment during actual step execution: '+$step.error)
    $session.tainted=$true # Loader fixture supplies no GUI route for qualification.
    Close-AGTAPlanSession $session | Out-Null;Remove-Module $session.module;$session=$null
    foreach ($dispatch in @('Invoke-PotatoJson state @()', '& $PotatoCliPath state', "& (Join-Path 'C:\fixture' 'potato.ps1') state")) {
        $source.Replace('$StepBodies=@(',($dispatch+"`n"+'$StepBodies=@(')) | Set-Content $path
        $errorRecord=$null;try {Get-AGTAPlanDefinition $path | Out-Null} catch {$errorRecord=$_}
        Check ($errorRecord -and $errorRecord.Exception.Message -match 'setup line.*GUI actions') 'Setup dispatch was accepted or lacked its offending source line.'
    }
    $source.Replace('$State=@{',"Join-Path `$null 'invalid'`n"+'$State=@{') | Set-Content $path
    $errorRecord=$null;try {Import-AGTAPlanSession $root $path | Out-Null} catch {$errorRecord=$_}
    Check ($errorRecord -and $errorRecord.ScriptStackTrace -match [regex]::Escape($path)) 'Null-path setup error lost its saved script location.'
    @{ok=$true;checks=$script:checks;psVersion=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress
} catch {
    Write-Output $_.ScriptStackTrace
    throw
} finally {
    if ($session) {Close-AGTAPlanSession $session | Out-Null;Remove-Module $session.module -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'agta-loader-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
