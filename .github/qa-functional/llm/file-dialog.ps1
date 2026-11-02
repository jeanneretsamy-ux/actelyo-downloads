# Drives the native Windows "Open" dialog opened by the app: types -File into the file-name box and presses Open.
param([Parameter(Mandatory)] [string] $File, [string] $Shot, [int] $TimeoutSec = 45)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
$A = [System.Windows.Automation.AutomationElement]
$T = [System.Windows.Automation.TreeScope]
$P = [System.Windows.Automation.PropertyCondition]
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$dlg = $null
while (-not $dlg -and (Get-Date) -lt $deadline) {
  $dlg = $A::RootElement.FindFirst($T::Descendants, (New-Object $P($A::ClassNameProperty, '#32770')))
  if (-not $dlg) { Start-Sleep -Milliseconds 500 }
}
if (-not $dlg) { Write-Host 'NO_DIALOG'; exit 2 }
Write-Host "dialog: $($dlg.Current.Name)"
$cond = New-Object System.Windows.Automation.AndCondition(
  (New-Object $P($A::AutomationIdProperty, '1148')),
  (New-Object $P($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
$edit = $dlg.FindFirst($T::Descendants, $cond)
if ($edit) {
  $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($File)
} else {
  Write-Host 'edit 1148 not found, using SendKeys'
  $dlg.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('%n'); Start-Sleep -Milliseconds 300
  [System.Windows.Forms.SendKeys]::SendWait(($File -replace '([+^%~(){}\[\]])', '{$1}'))
}
Start-Sleep -Milliseconds 500
if ($Shot) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
  $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
$open = $dlg.FindFirst($T::Children, (New-Object $P($A::AutomationIdProperty, '1')))
if ($open) { $open.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
else { $dlg.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
Start-Sleep -Seconds 1
Write-Host 'OK'
