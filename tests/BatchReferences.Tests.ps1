param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'Framework\Exploration.ps1')
$script:checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
function Reject([scriptblock]$body) {$caught=$false;try {& $body | Out-Null} catch {$caught=$true};Check $caught 'Invalid reference/policy was accepted.'}
$baseline=@{stepIndex=1;command='windows';key='baseline';arguments=@('-Checkpoint')}
$focus=@{stepIndex=1;command='focus';arguments=@('-SinceCheckpoint',@{resultRef='baseline';path='data.checkpointId'})}
Assert-AGTABatchRequests @($baseline,$focus) 1 GuiNavigation
$results=@{baseline=@{ok=$true;data=@{checkpointId='actual-checkpoint';foregroundSelector=@{Name='Fixture';ClassName='Native';ProcessId=42;NativeWindowHandle=123}}}}
$resolved=@(Resolve-AGTABatchArguments focus $focus.arguments $results GuiNavigation)
Check ($resolved[1] -ceq 'actual-checkpoint' -and $focus.arguments[1].resultRef -ceq 'baseline') 'Fresh binding changed the request or used the receipt ID.'
$guard=@{stepIndex=1;command='observe';arguments=@('-Scope','ForegroundWindow','-WindowSelectorJson',@{resultRef='baseline';path='data.foregroundSelector'})}
Assert-AGTABatchRequests @($baseline,$guard) 1 GuiNavigation
$resolved=@(Resolve-AGTABatchArguments observe $guard.arguments $results GuiNavigation)
$value=$resolved[3] | ConvertFrom-Json
Check ($value.NativeWindowHandle -eq 123 -and $value.ProcessId -eq 42 -and $resolved[-1] -eq 'Compact') 'Guard object binding lost identity or compact formatting.'
Reject {Assert-AGTABatchRequests @($focus,$baseline) 1 GuiNavigation}
Reject {Assert-AGTABatchRequests @($baseline,$baseline) 1 GuiNavigation}
foreach ($option in @('-Text','-ClearMethod','-InteractionPolicy','-Name','-Arguments')) {
    Reject {Assert-AGTABatchRequests @($baseline,@{stepIndex=1;command='type';arguments=@($option,@{resultRef='baseline';path='data.checkpointId'})}) 1 GuiNavigation}
}
Reject {Assert-AGTABatchRequests @($baseline,@{stepIndex=1;command='focus';arguments=@(@{resultRef='baseline';path='data.checkpointId'})}) 1 GuiNavigation}
Reject {Assert-AGTABatchRequests @($baseline,@{stepIndex=1;command='hotkey';arguments=@('-Keys','Ctrl+P')}) 1 GuiNavigation}
Reject {Assert-AGTABatchRequests @($baseline,@{stepIndex=1;command='focus';arguments=@('-SinceCheckpoint',@{resultRef='baseline';path='data.checkpointId';extra='not allowed'})}) 1 GuiNavigation}
Reject {Assert-AGTABatchRequests @($baseline,@{stepIndex=1;command='focus';arguments=@('-SinceCheckpoint',@{resultRef='baseline';path='data.checkpointId.ToString()'})}) 1 GuiNavigation}
Reject {Resolve-AGTABatchArguments focus @('-SinceCheckpoint',@{resultRef='baseline';path='data.missing'}) $results GuiNavigation}
Reject {Resolve-AGTABatchArguments focus $focus.arguments @{baseline=@{ok=$false;data=@{checkpointId='must not use'}}} GuiNavigation}
Check ($results.baseline.data.foregroundSelector.NativeWindowHandle -eq 123) 'Binding mutated its source receipt.'
'Batch references: '+$script:checks+' checks passed.'
