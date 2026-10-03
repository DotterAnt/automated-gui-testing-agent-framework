param([string]$Root,[string]$Title,[switch]$Menus)
$fixture=Join-Path $Root 'dialog.ps1'
@'
param($Title,[switch]$Menus)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class FixtureForegroundPermission {
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
}
"@
$form=New-Object Windows.Forms.Form
$form.Text=$Title;$form.Width=700;$form.Height=170
$field=New-Object Windows.Forms.TextBox
$field.Name='Filename';$field.AccessibleName='Fixture filename';$field.SetBounds(10,10,660,30)
$form.Controls.Add($field)
if ($Menus) {
    $form.Height=210;$field.Top=40
    function Show-FixtureDialog($DialogTitle) {
        $script:fixtureDialogTitle=$DialogTitle
        $script:menuTimer=New-Object Windows.Forms.Timer
        $script:menuTimer.Interval=50
        $script:menuTimer.Add_Tick({
            $script:menuTimer.Stop()
            $dialog=New-Object Windows.Forms.Form
            $dialog.Text=$script:fixtureDialogTitle;$dialog.Width=300;$dialog.Height=150
            $cancel=New-Object Windows.Forms.Button
            $cancel.Text='Fixture Cancel';$cancel.AccessibleName=$cancel.Text;$cancel.SetBounds(10,10,150,40)
            $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
            $dialog.Controls.Add($cancel)
            try {[void]$dialog.ShowDialog($form)} finally {$dialog.Dispose();$script:menuTimer.Dispose()}
        })
        $script:menuTimer.Start()
    }
    $menu=New-Object Windows.Forms.MenuStrip
    $file=New-Object Windows.Forms.ToolStripMenuItem('Fixture File')
    $open=New-Object Windows.Forms.ToolStripMenuItem('Fixture Open command')
    $print=New-Object Windows.Forms.ToolStripMenuItem('Fixture Print command')
    $open.Add_Click({Show-FixtureDialog 'Fixture Open'})
    $print.Add_Click({Show-FixtureDialog 'Fixture Print'})
    [void]$file.DropDownItems.Add($open);[void]$file.DropDownItems.Add($print)
    [void]$menu.Items.Add($file);$form.MainMenuStrip=$menu;$form.Controls.Add($menu)
}
$form.Add_Shown({$field.Focus();[void][FixtureForegroundPermission]::AllowSetForegroundWindow(-1)})
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
$arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$Title+'"'))
if ($Menus) {$arguments+=,'-Menus'}
Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $arguments
