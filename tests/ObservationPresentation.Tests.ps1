param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'Framework\Exploration.ps1')
$checks=0
function Check($ok,$message) {if (-not $ok) {throw $message};$script:checks++}
$elements=@(foreach ($index in 1..120) {
    [pscustomobject]@{depth=($index % 6);name=('Control '+$index+' '+[char]0x151);id=([string]$index);role='Button';className='Native';
        enabled=($index % 7 -ne 0);offscreen=($index % 13 -eq 0);focused=($index -eq 3);ambiguous=($index -eq 4);
        bounds=@{x=-10.5;y=($index*2);width=20;height=30};patterns=@('Invoke');selector=@{AutomationId=([string]$index);Regex=$true};propertyErrors=@()}
})
$data=[pscustomobject]@{elements=$elements;root=@{name='Fixture';nativeWindowHandle=123};keyboardFocus=@{ready=$true;focusHandle=456};limitReached=$true}
$rows=ConvertTo-AGTAObservationRows $data
$encoded=$rows | ConvertTo-Json -Depth 20 -Compress
$roundtrip=$encoded | ConvertFrom-Json
Check ($roundtrip.elementRows.Count -eq 120 -and -not $roundtrip.elements) 'Presentation lost nodes or retained duplicated object rows.'
Check ($roundtrip.elementColumns.Count -eq 10 -and $roundtrip.root.nativeWindowHandle -eq 123 -and $roundtrip.keyboardFocus.focusHandle -eq 456 -and $roundtrip.limitReached) 'Identity, focus or traversal limits were lost.'
foreach ($index in 0..119) {
    $source=$elements[$index];$row=$roundtrip.elementRows[$index]
    Check ($row.Count -eq 10 -and $row[0] -eq $source.depth -and $row[1] -ceq $source.name -and $row[2] -ceq $source.id -and $row[3] -eq $source.role -and $row[4] -eq $source.className) 'Selector labels or depth changed.'
    Check ($row[5][0] -eq -10.5 -and $row[5][1] -eq $source.bounds.y -and $row[6][0] -eq 'Invoke' -and $row[7].AutomationId -ceq $source.id -and $row[7].Regex) 'Physical bounds, patterns or exact selectors changed.'
    Check ((('focused' -in $row[8]) -eq $source.focused) -and (('disabled' -in $row[8]) -eq (-not $source.enabled)) -and (('offscreen' -in $row[8]) -eq $source.offscreen) -and (('ambiguous' -in $row[8]) -eq $source.ambiguous)) 'State flags changed.'
}
$old=$data | ConvertTo-Json -Depth 20 -Compress
Check ($encoded.Length -lt $old.Length*0.65) 'Repeated discovery keys were not reduced meaningfully.'
$single=ConvertTo-AGTAObservationRows @{elements=@($elements[0]);root=@{name='Single'}}
$single=$single | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
Check ($single.elementRows.Count -eq 1 -and $single.elementRows[0].Count -eq 10 -and -not $single.Keys) 'Single-row/dictionary presentation flattened its arrays or included hashtable metadata.'
$full=[pscustomobject]@{elements=@(@{element=@{name='Full tree'}})}
Check ([object]::ReferenceEquals((ConvertTo-AGTAObservationRows $full),$full)) 'Explicit full CLI tree was reformatted.'
Check ((Test-AGTAReadOnlyCommand help) -and -not (Test-AGTAReadOnlyCommand type)) 'Shared help/input classification is wrong.'
$withoutErrors=$elements[0] | Select-Object * -ExcludeProperty propertyErrors
$missing=ConvertTo-AGTAObservationRows @{elements=@($withoutErrors)}
Check ($missing.elementRows[0][9].Count -eq 0) 'Absent property errors were padded with a null value.'
"Observation presentation: $checks checks passed; object $($old.Length), row $($encoded.Length) characters."
