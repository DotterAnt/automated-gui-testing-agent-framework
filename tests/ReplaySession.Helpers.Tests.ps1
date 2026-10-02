param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $frameworkRoot 'Framework\ReplaySession.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-helpers-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$session=$null;$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
try {
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','First,,Fixture','Second,,Fixture','Third,,Fixture' | Set-Content $csv
    Initialize-AGTAExploration $root $csv GuiNavigation (Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1') | Out-Null
    $template=[IO.File]::ReadAllText((Join-Path $frameworkRoot 'templates\GeneratedScript.Template.ps1'))
    $source=$template.Substring(0,$template.IndexOf('$StepBodies = @('))+@'
$State=@{starts=1;value=0}
function Get-FixtureValue { throw 'Fixture helper failure' }
function Get-RemovedHelper { 'unused' }
$StepBodies=@(
    {param([ref]$Commands,[ref]$Evidence) $State.value++;Assert-ExpectedResult ($State.value -eq 1) 'First row ran once'},
    {param([ref]$Commands,[ref]$Evidence) Assert-ExpectedResult ((Get-FixtureValue) -eq 'expected') 'Edited helper returns expected value'},
    {param([ref]$Commands,[ref]$Evidence) Assert-ExpectedResult ($State.value -eq 1 -and $State.starts -eq 1) 'Setup and successful prefix retained';Assert-ExpectedResult ((Get-RemovedHelper) -eq 'unused') 'Helper retains module context'}
)
Invoke-AGTATestPlan -StepBodies $StepBodies -OutputMode $OutputMode
exit (Get-AGTATestExitCode)
'@
    $path=Join-Path $root 'generated.ps1';$source | Set-Content $path
    $session=Import-AGTAPlanSession $root $path
    Check (-not (Get-Command Get-FixtureValue -ErrorAction SilentlyContinue)) 'Plan helpers leaked into the caller instead of remaining in the isolated module.'
    & $session.module {function script:Invoke-EvidenceScreenshot {throw 'Fixture: desktop capture disabled'}}
    $originalContext=$session.context;$originalModule=$session.module
    $first=Invoke-AGTAPlanStep $session
    Check ($first.ok -and $first.countsAsSuccessfulStep -and $session.nextStepIndex -eq 2) 'First row did not advance once.'
    $failure=Invoke-AGTAPlanStep $session
    Check (-not $failure.ok -and $session.nextStepIndex -eq 2) 'Helper fixture did not retain a failed row.'
    Check (($failure.location.stack -join ' ') -match [regex]::Escape($path)) 'Helper failure did not report its saved source location.'
    Get-AGTAPlanStatus $session | Out-Null
    $edited=$source.Replace("function Get-FixtureValue { throw 'Fixture helper failure' }","function Get-FixtureValue { 'expected' }").Replace("function Get-RemovedHelper { 'unused' }","function Get-AddedHelper { `$Context.ExecutionEvidenceRoot }").Replace("(Get-RemovedHelper) -eq 'unused'",'(Get-AddedHelper) -eq $Context.ExecutionEvidenceRoot')
    $edited | Set-Content $path
    $definition=Get-AGTAPlanDefinition $path
    Check ($definition.setupHash -eq $session.definition.setupHash -and $definition.helpersHash -ne $session.definition.helpersHash) 'Helper changes were classified as initializers.'
    $retry=Invoke-AGTAPlanStep $session
    Check ($retry.ok -and $retry.status -eq 'RECOVERY_SUCCESS' -and -not $retry.countsAsSuccessfulStep) ('Edited helper could not reload in place: '+$retry.error)
    Check ([object]::ReferenceEquals($session.context,$originalContext) -and [object]::ReferenceEquals($session.module,$originalModule)) 'Helper reload replaced the retained context/module.'
    Check ((& $session.module {$State.value}) -eq 1 -and (& $session.module {$State.starts}) -eq 1) 'Helper reload reran setup or the successful prefix.'
    Check (-not (& $session.module {Get-Command Get-RemovedHelper -ErrorAction SilentlyContinue})) 'Removed helper remained callable.'
    Check ((& $session.module {Get-AddedHelper}) -eq $session.context.ExecutionEvidenceRoot) 'Added helper lost module scope.'
    $third=Invoke-AGTAPlanStep $session
    Check ($third.ok -and $third.countsAsSuccessfulStep) 'Later first-attempt success was lost after helper recovery.'
    $closed=Close-AGTAPlanSession $session
    Check (-not $closed.qualifying -and $session.attempts.Count -eq 4 -and $session.tainted) 'Helper recovery erased the failure history or qualified a repaired run.'
    $edited.Replace('$State=@{starts=1;value=0}','$State=@{starts=2;value=0}') | Set-Content $path
    $caught=$null;try {Update-AGTAPlanSession $session} catch {$caught=$_}
    Check ($caught.Exception.Message -match 'setup changed' -and (& $session.module {$State.starts}) -eq 1) 'Initializer edit was executed over live state.'
    @{ok=$true;checks=$script:checks;psVersion=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress
} finally {
    if ($session) {if (-not $session.closed) {$session.tainted=$true;Close-AGTAPlanSession $session | Out-Null};Remove-Module $session.module -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'agta-helpers-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
