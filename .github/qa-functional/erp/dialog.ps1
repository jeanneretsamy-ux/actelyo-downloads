# Fills a native Windows file dialog (Open or Save As) opened by the app,
# the way a user would: type the full path in "File name" and press Open/Save.
# Usage: dialog.ps1 -Path C:\x\file.docx -Shot C:\x\shot.png [-TimeoutSec 60]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$Shot = '',
  [int]$TimeoutSec = 60
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
$PC = [System.Windows.Automation.PropertyCondition]

function Take-Shot([string]$file) {
  if (-not $file) { return }
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

function Find-Dialog {
  $cls = New-Object $PC ($AE::ClassNameProperty, '#32770')
  $d = $AE::RootElement.FindFirst($TS::Children, $cls)
  if ($d) { return $d }
  # Owned dialogs can be exposed under their owner window.
  foreach ($w in $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    try {
      if ($w.Current.Name -like 'Actelyo*') {
        $d = $w.FindFirst($TS::Children, $cls)
        if ($d) { return $d }
      }
    } catch {}
  }
  return $null
}

function Find-NameEdit($dlg) {
  $edits = $dlg.FindAll($TS::Descendants, (New-Object $PC ($AE::ControlTypeProperty, $CT::Edit)))
  foreach ($e in $edits) { if ($e.Current.Name -match '^File name') { return $e } }
  foreach ($e in $edits) { if (@('1148', '1001') -contains $e.Current.AutomationId) { return $e } }
  return $null
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$dlg = $null
while ((Get-Date) -lt $deadline) {
  $dlg = Find-Dialog
  if ($dlg) { break }
  Start-Sleep -Milliseconds 400
}
if (-not $dlg) { Write-Output 'NO_DIALOG'; exit 2 }
Write-Output ("DIALOG title='" + $dlg.Current.Name + "' pid=" + $dlg.Current.ProcessId)
Start-Sleep -Milliseconds 800
$edit = $null
while ((Get-Date) -lt $deadline -and -not $edit) { $edit = Find-NameEdit $dlg; if (-not $edit) { Start-Sleep -Milliseconds 300 } }
if (-not $edit) { Write-Output 'NO_EDIT'; exit 3 }
try { $dlg.SetFocus() } catch {}
$vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$vp.SetValue($Path)
Start-Sleep -Milliseconds 400
Write-Output ("TYPED value='" + $vp.Current.Value + "'")
Take-Shot $Shot
$btn = $dlg.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition (
  (New-Object $PC ($AE::ControlTypeProperty, $CT::Button)),
  (New-Object $PC ($AE::AutomationIdProperty, '1')))))
if ($btn) {
  Write-Output ("PRESS '" + $btn.Current.Name + "'")
  $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
} else {
  $edit.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Write-Output 'PRESS ENTER'
}
# Wait for the dialog to close; retry once with Enter if it is still open.
$closeBy = (Get-Date).AddSeconds(15)
$retried = $false
while ((Get-Date) -lt $closeBy) {
  Start-Sleep -Milliseconds 500
  $still = $false
  try { $null = $dlg.Current.Name; $still = -not $dlg.Current.IsOffscreen } catch { $still = $false }
  if (-not $still) { Write-Output 'CLOSED'; exit 0 }
  if (-not $retried -and (Get-Date) -gt $closeBy.AddSeconds(-8)) {
    $retried = $true
    try { $edit.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Write-Output 'RETRY ENTER' } catch {}
  }
}
Write-Output 'STILL_OPEN'
# Leave no blocking dialog behind.
try {
  $cancel = $dlg.FindFirst($TS::Descendants, (New-Object $PC ($AE::AutomationIdProperty, '2')))
  if ($cancel) { $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Write-Output 'CANCELLED' }
} catch {}
exit 4
