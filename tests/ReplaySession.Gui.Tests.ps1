param()
$ErrorActionPreference='Stop'
$frameworkRoot=Split-Path $PSScriptRoot
. (Join-Path $frameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
. (Join-Path $frameworkRoot 'Framework\ReplaySession.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-live-gui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$session=$null;$verification=$null;$script:checks=0
function Check($condition,$message) {if (-not $condition) {throw $message};$script:checks++}
try {
    $exe=Join-Path $root 'Fixture.exe';$compiler=Join-Path $root 'compile.ps1'
    @'
param([string]$Path)
$ErrorActionPreference='Stop'
Add-Type -OutputAssembly $Path -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;
public static class Fixture {
    [STAThread] public static void Main() {
        var form=new Form { Text="AGTA live replay fixture", Width=400, Height=200 };
        var label=new Label { Text="Ready", Left=20, Top=20, Width=200 };
        var button=new Button { Text="Mark", Left=20, Top=70, Width=100 };
        button.Click+=(sender,args)=>{label.Text="Marked";};
        form.Controls.Add(label); form.Controls.Add(button); Application.Run(form);
    }
}
"@
'@ | Set-Content $compiler
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compiler -Path $exe
    Check ($LASTEXITCODE -eq 0 -and (Test-Path $exe)) 'Could not compile isolated GUI fixture.'
    $csv=Join-Path $root 'case.csv'
    'Action,Data,Expected Result','Open fixture,,Ready label','Mark fixture,,Marked label' | Set-Content $csv
    $cli=Join-Path (Split-Path $frameworkRoot) 'potato-cli\potato.ps1'
    Initialize-AGTAExploration $root $csv GuiNavigation $cli | Out-Null
    $path=Join-Path $root 'generated.ps1'
    $source=@'
[CmdletBinding()]
param([string]$PotatoCliPath,[string]$TestCaseCsv,[string]$RunRoot,[string]$FrameworkRoot,[string]$ExplorationPath,[string]$InteractionPolicy='GuiNavigation',[string]$Transport='InProcess',[string]$OutputMode='Compact')
. (Join-Path $FrameworkRoot 'Framework\GeneratedScriptRuntime.ps1')
$Context=Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot -ExplorationPath $ExplorationPath -InteractionPolicy $InteractionPolicy -Transport $Transport
$State=@{started=$null}
$FixtureExe=Join-Path $RunRoot 'Fixture.exe'
$StepBodies=@(
    {param([ref]$Commands,[ref]$Evidence)
        $State.started=Invoke-StepCommand $Commands start @('-ProcessName',$FixtureExe,'-WaitForWindowMs','10000')
        Assert-PotatoOk $State.started
        $ready=Invoke-StepCommand $Commands wait-element @('-Name','Ready','-TimeoutMs','3000')
        Assert-PotatoFound $ready 'Ready label is visible'
    },
    {param([ref]$Commands,[ref]$Evidence)
        $marked=Invoke-StepCommand $Commands click @('-Name','Missing button','-TimeoutMs','0')
        Assert-PotatoOk $marked
        $label=Invoke-StepCommand $Commands wait-element @('-Name','Marked','-TimeoutMs','3000')
        Assert-PotatoFound $label 'Click changed the visible label'
    }
)
Invoke-AGTATestPlan -StepBodies $StepBodies -OutputMode $OutputMode
exit (Get-AGTATestExitCode)
'@
    $source | Set-Content $path
    $session=Import-AGTAPlanSession $root $path
    $first=Invoke-AGTAPlanStep $session
    Check $first.ok ('Fixture startup failed: '+$first.error)
    Complete-AGTAExplorationStep $root 1 'Started isolated fixture' 'Ready label visible' $first.verificationCommandIds | Out-Null
    $ownedId=& $session.module {$State.started.data.ownedProcessId}
    Check ([bool]$ownedId) 'Runtime did not retain process ownership.'
    $failure=Invoke-AGTAPlanStep $session
    Check (-not $failure.ok -and [bool](Get-Process -Id $ownedId -ErrorAction SilentlyContinue) -and $session.context.ActiveStep -eq 0) 'Failure closed the owned window or lost the live context.'
    Get-AGTAPlanStatus $session | Out-Null
    $inspection=@(Invoke-AGTAPlanRepair $session @(@{command='windows';arguments=@('-Foreground')}))
    Check ($inspection[0].ok -and $inspection[0].data.foregroundSelector.Name -eq 'AGTA live replay fixture') 'Read-only inspection lost the actual live GUI.'
    $source.Replace('Missing button','Mark') | Set-Content $path
    $retry=Invoke-AGTAPlanStep $session
    Check ($retry.ok -and $retry.status -eq 'RECOVERY_SUCCESS') ('Edited body did not recover in place: '+$retry.error)
    Complete-AGTAExplorationStep $root 2 'Clicked visible Mark button' 'Marked label visible' $retry.verificationCommandIds | Out-Null
    $closed=Close-AGTAPlanSession $session
    Check ($closed.cleanupOk -and -not $closed.qualifying -and -not (Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) 'Diagnostic close lost owned cleanup or qualification boundaries.'
    Complete-AGTAExploration $root $csv GuiNavigation | Out-Null
    $verification=Import-AGTAPlanSession $root $path Replay
    $full=& $verification.module {Invoke-AGTATestPlan -StepBodies $script:StepBodies} | ConvertFrom-Json
    Check ($full.ok -and $full.qualifying -and $full.summary.passed -eq 2 -and $full.cleanupOk) 'One fresh full replay failed after successful live repair.'
    $newId=& $verification.module {$State.started.data.ownedProcessId}
    Check (-not (Get-Process -Id $newId -ErrorAction SilentlyContinue)) 'Fresh replay left its owned fixture running.'
    @{ok=$true;checks=$script:checks;psVersion=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress
} finally {
    foreach ($live in @($session,$verification) | Where-Object {$_}) {
        try {& $live.module {Invoke-TestCleanup} | Out-Null} catch {}
        Remove-Module $live.module -ErrorAction SilentlyContinue
    }
    $resolved=[IO.Path]::GetFullPath($root)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'agta-live-gui-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
