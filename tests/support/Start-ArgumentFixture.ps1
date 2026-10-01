param([string]$Root,[string]$Title)
$fixture=Join-Path $Root 'dialog.ps1'
@'
param($Title)
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text=$Title;$form.Width=700;$form.Height=170
$field=New-Object Windows.Forms.TextBox
$field.Name='Filename';$field.AccessibleName='Fixture filename';$field.SetBounds(10,10,660,30)
$form.Controls.Add($field)
$form.Add_Shown({$field.Focus()})
$form.Show();$form.Hide()
[void]$form.ShowDialog()
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$fixture+'"'),'-Title',('"'+$Title+'"'))
