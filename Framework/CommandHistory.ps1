function Get-AGTACommandDiagnostics {
    param([string]$Path,[ValidateRange(1,20)] [int]$Last=3,[int]$StepIndex=0)
    if (-not [IO.File]::Exists($Path)) {return}
    $queue=New-Object 'Collections.Generic.Queue[object]'
    $reader=[IO.File]::OpenText($Path)
    try {
        while ($null -ne ($line=$reader.ReadLine())) {
            $entry=$line | ConvertFrom-Json
            if ($StepIndex -and $entry.stepIndex -ne $StepIndex) {continue}
            $queue.Enqueue($entry);if ($queue.Count -gt $Last) {[void]$queue.Dequeue()}
        }
    } finally {$reader.Dispose()}
    foreach ($entry in $queue) {
        $result=if ($entry.parsed) {$entry.parsed} else {$entry.result}
        $data=[ordered]@{}
        foreach ($name in @('action','target','inputFocus','verification','path','region','visualWait','conditionMet','text','content','count','root','search','foregroundSelector','focusedElement','keyboardFocus')) {
            if ($null -ne $result.data.$name) {$data[$name]=$result.data.$name}
        }
        if ($result.data.elements) {$data.elements=@($result.data.elements | Select-Object -First 20);$data.elementsOmitted=[Math]::Max(0,$result.data.elements.Count-20)}
        [ordered]@{index=$entry.index;id=$entry.id;stepIndex=$entry.stepIndex;command=$entry.command;arguments=$entry.arguments;
            ok=$result.ok;outcome=$result.outcome;durationMs=$result.durationMs;error=$result.error;data=$data;fullLogPath=$Path}
    }
}
