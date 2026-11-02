# Fills a native Windows file dialog (Open, Save As or folder picker) opened by
# the app, the way a user would: type the full path in "File name"/"Folder" and
# press Open/Save/Select Folder. Always cancels the dialog on failure.
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
  try {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  } catch { Write-Host ('SHOT_ERR ' + $_.Exception.Message) }
}

function Find-Dialog {
  $cls = New-Object $PC ($AE::ClassNameProperty, '#32770')
  $d = $AE::RootElement.FindFirst($TS::Children, $cls)
  if ($d) { return $d }
  foreach ($w in $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    try { if ($w.Current.Name -like 'Actelyo*') { $d = $w.FindFirst($TS::Children, $cls); if ($d) { return $d } } } catch {}
  }
  return $null
}

function Find-NameEdit($dlg) {
  # 1. The file-name / folder combo box host used by IFileDialog.
  $hostEl = $dlg.FindFirst($TS::Descendants, (New-Object $PC ($AE::AutomationIdProperty, 'FileNameControlHost')))
  if ($hostEl) {
    $e = $hostEl.FindFirst($TS::Descendants, (New-Object $PC ($AE::ControlTypeProperty, $CT::Edit)))
    if ($e) { Write-Host 'EDIT via FileNameControlHost'; return $e }
  }
  # 2. By label (English / French Windows) or by classic control ids.
  $edits = $dlg.FindAll($TS::Descendants, (New-Object $PC ($AE::ControlTypeProperty, $CT::Edit)))
  foreach ($e in $edits) { if ($e.Current.Name -match '^(File name|Folder|Dossier|Nom du fichier)') { Write-Host ("EDIT via name '" + $e.Current.Name + "'"); return $e } }
  foreach ($e in $edits) { if (@('1148', '1001', '1152') -contains $e.Current.AutomationId) { Write-Host ('EDIT via id ' + $e.Current.AutomationId); return $e } }
  foreach ($e in $edits) { Write-Host ("EDIT? name='" + $e.Current.Name + "' id=" + $e.Current.AutomationId) }
  return $null
}
function Is-Open { try { $null = $dlg.Current.Name; return (-not $dlg.Current.IsOffscreen) } catch { return $false } }
function Cancel-Dialog {
  try {
    $cancel = $dlg.FindFirst($TS::Descendants, (New-Object $PC ($AE::AutomationIdProperty, '2')))
    if ($cancel) { $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Write-Output 'CANCELLED' }
    else { $dlg.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{ESC}'); Write-Output 'CANCELLED (Esc)' }
  } catch { Write-Output ('CANCEL_ERR ' + $_.Exception.Message) }
  Start-Sleep -Milliseconds 800
  if (Is-Open) { try { $dlg.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{ESC}') } catch {} }
}
function Fail([string]$why, [int]$code) { Write-Output $why; Cancel-Dialog; exit $code }
function Press-Default {
  $btn = $dlg.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition (
    (New-Object $PC ($AE::ControlTypeProperty, $CT::Button)),
    (New-Object $PC ($AE::AutomationIdProperty, '1')))))
  if ($btn) {
    Write-Host ("PRESS '" + $btn.Current.Name + "'")
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  } else { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Write-Host 'PRESS ENTER' }
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$dlg = $null
while ((Get-Date) -lt $deadline) { $dlg = Find-Dialog; if ($dlg) { break }; Start-Sleep -Milliseconds 400 }
if (-not $dlg) { Write-Output 'NO_DIALOG'; exit 2 }
Write-Output ("DIALOG title='" + $dlg.Current.Name + "' pid=" + $dlg.Current.ProcessId)
Start-Sleep -Milliseconds 1000
try { $dlg.SetFocus() } catch {}

$edit = $null
$editBy = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $editBy -and -not $edit) { $edit = Find-NameEdit $dlg; if (-not $edit) { Start-Sleep -Milliseconds 400 } }
$typed = $false
if ($edit) {
  try {
    $vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $vp.SetValue($Path); Start-Sleep -Milliseconds 400
    Write-Output ("TYPED value='" + $vp.Current.Value + "'")
    $typed = ($vp.Current.Value -eq $Path)
  } catch { Write-Output ('SETVALUE_ERR ' + $_.Exception.Message) }
}
if (-not $typed) {
  # Fallback: type into the focused field (the name box has focus by default), as a user would.
  try {
    if ($edit) { $edit.SetFocus() } else { $dlg.SetFocus() }
    $focused = $AE::FocusedElement
    Write-Output ("FOCUSED name='" + $focused.Current.Name + "' type=" + $focused.Current.ControlType.ProgrammaticName)
    $escaped = ($Path -replace '([+^%~(){}\[\]])', '{$1}')
    [System.Windows.Forms.SendKeys]::SendWait('^a'); [System.Windows.Forms.SendKeys]::SendWait($escaped)
    Start-Sleep -Milliseconds 400
    Write-Output 'TYPED via keyboard'
    $typed = $true
  } catch { Fail ('TYPE_ERR ' + $_.Exception.Message) 3 }
}
Take-Shot $Shot
# Folder pickers may first navigate into the typed folder: press the default
# button again (a user would click "Select Folder" a second time).
for ($attempt = 1; $attempt -le 4; $attempt++) {
  try { if ($attempt -eq 1 -and -not $edit) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Write-Host 'PRESS ENTER' } else { Press-Default } } catch { Write-Output ('PRESS_ERR ' + $_.Exception.Message) }
  for ($i = 0; $i -lt 8; $i++) { Start-Sleep -Milliseconds 500; if (-not (Is-Open)) { Write-Output "CLOSED after $attempt press(es)"; exit 0 } }
  if ($attempt -eq 2) { Take-Shot ($Shot -replace '\.png$', '-retry.png') }
}
Fail 'STILL_OPEN' 4
