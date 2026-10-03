param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'Framework\GeneratedScriptRuntime.ps1')
$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
function Reject([scriptblock]$Body,$message) {$caught=$null;try {& $Body} catch {$caught=$_};Check ([bool]$caught) $message}
$script:AGTAGeneratedTestContext=[pscustomobject]@{StartedAt=Get-Date}
$script:AGTAStepAssertions=@()
$ok=@{ok=$true;command='wait-element';data=@{exists=$true}}
$missing=@{ok=$true;command='wait-element';data=@{exists=$false}}
$bad=@{ok=$false;error=@{message='Fixture failure'};data=$null}
$file=@{ok=$true;command='wait-file';data=@{conditionMet=$true;path='fixture';lastWriteTimeUtc=[DateTime]::UtcNow.AddSeconds(1).ToString('o')}}
$stale=@{ok=$true;command='wait-file';data=@{conditionMet=$true;path='fixture';lastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-1).ToString('o')}}
$text=@{ok=$true;command='read';data=@{text='Actual fixture needle';textSource='ValuePattern'}}
$wrong=@{ok=$true;command='read';data=@{text='Wrong fixture';textSource='ValuePattern'}}
foreach ($call in @(
    {$ok | Assert-PotatoOk},
    {$ok | Assert-PotatoFound},
    {$file | Assert-FileWait},
    {$text | Assert-TextContains -Expected 'needle'}
)) {
    Check (@(& $call).Count -eq 0) 'A piped assertion leaked a receipt into its caller.'
}
Check ($script:AGTAStepAssertions.Count -eq 5 -and -not @($script:AGTAStepAssertions | Where-Object {-not $_.passed}).Count) 'Pipeline assertions lost actual expected-result records.'
Reject {@($bad,$ok) | Assert-PotatoOk} 'Piped command assertion ignored a failed first receipt.'
Reject {@($missing,$ok) | Assert-PotatoFound} 'Piped presence assertion ignored a missing first target.'
Reject {@($stale,$file) | Assert-FileWait} 'Piped file assertion accepted an old output before a fresh one.'
Reject {@($wrong,$text) | Assert-TextContains -Expected 'needle'} 'Piped text assertion checked only the last receipt.'
Reject {@{ok=$true;data=@{visualWait=@{conditionMet=$false;mode='ExpectedImage'}}} | Assert-PotatoOk} 'Piped assertion accepted unmet expected pixels.'
Reject {@{ok=$true;data=@{verificationPerformed=$true;verified=$false}} | Assert-PotatoOk} 'Piped assertion accepted failed text readback.'
Reject {'needle' | Assert-TextContains -Expected 'needle'} 'A plain string bypassed content provenance.'
$before=$script:AGTAStepAssertions.Count
@($ok,$ok) | Assert-PotatoFound
Check ($script:AGTAStepAssertions.Count -eq $before+2) 'Presence assertion did not process every pipeline receipt.'
Assert-PotatoOk -Result $ok
Assert-PotatoFound -Result $ok
Assert-FileWait -Result $file
Assert-TextContains -Result $text -Expected 'needle'
Check ($script:AGTAStepAssertions.Count -eq $before+7) 'Direct invocation changed while adding pipeline support.'
'Pipeline assertions: '+$script:checks+' checks passed.'
