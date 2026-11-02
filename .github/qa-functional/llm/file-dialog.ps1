# Drives the native Windows "Open" dialog opened by the app (title starting with -TitlePrefix):
# puts -File in the file-name box (control 1148) with WM_SETTEXT and clicks Open (control 1) with BM_CLICK.
param([Parameter(Mandatory)] [string] $File, [string] $Shot, [string] $TitlePrefix = 'Importer', [int] $TimeoutSec = 45)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace QA -Name Dlg -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDlgItem(System.IntPtr h, int id);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr FindWindowEx(System.IntPtr p, System.IntPtr after, string cls, string title);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, int msg, System.IntPtr w, string l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, int msg, System.IntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
public static System.IntPtr Find(string prefix) {
  System.IntPtr found = System.IntPtr.Zero;
  EnumWindows((h, l) => {
    var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
    var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
    if (c.ToString() == "#32770" && IsWindowVisible(h) && t.ToString().StartsWith(prefix)) { found = h; return false; }
    return true; }, System.IntPtr.Zero);
  return found;
}
'@
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$dlg = [IntPtr]::Zero
while ($dlg -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { $dlg = [QA.Dlg]::Find($TitlePrefix); if ($dlg -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500 } }
if ($dlg -eq [IntPtr]::Zero) { Write-Host 'NO_DIALOG'; exit 2 }
Start-Sleep -Milliseconds 800
$combo = [QA.Dlg]::GetDlgItem($dlg, 1148)
$edit = [IntPtr]::Zero
if ($combo -ne [IntPtr]::Zero) {
  $cb = [QA.Dlg]::FindWindowEx($combo, [IntPtr]::Zero, 'ComboBox', $null)
  $edit = if ($cb -ne [IntPtr]::Zero) { [QA.Dlg]::FindWindowEx($cb, [IntPtr]::Zero, 'Edit', $null) } else { [QA.Dlg]::FindWindowEx($combo, [IntPtr]::Zero, 'Edit', $null) }
}
Write-Host "dialog=$dlg combo1148=$combo edit=$edit"
[QA.Dlg]::SetForegroundWindow($dlg) | Out-Null
if ($edit -ne [IntPtr]::Zero) { [QA.Dlg]::SendMessage($edit, 0x000C, [IntPtr]::Zero, $File) | Out-Null }   # WM_SETTEXT
else { [System.Windows.Forms.SendKeys]::SendWait('%n'); Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait(($File -replace '([+^%~(){}\[\]])', '{$1}')) }
Start-Sleep -Milliseconds 500
if ($Shot) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
  $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
$ok = [QA.Dlg]::GetDlgItem($dlg, 1)
if ($ok -ne [IntPtr]::Zero) { [QA.Dlg]::PostMessage($ok, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null; Write-Host 'BM_CLICK Open' }   # BM_CLICK
else { [QA.Dlg]::SetForegroundWindow($dlg) | Out-Null; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Write-Host 'ENTER' }
for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if ([QA.Dlg]::Find($TitlePrefix) -eq [IntPtr]::Zero) { Write-Host 'dialog closed'; exit 0 } }
Write-Host 'dialog still open, pressing ENTER'
[QA.Dlg]::SetForegroundWindow($dlg) | Out-Null; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Seconds 2
if ([QA.Dlg]::Find($TitlePrefix) -ne [IntPtr]::Zero) { Write-Host 'DIALOG_STILL_OPEN'; [System.Windows.Forms.SendKeys]::SendWait('{ESC}'); exit 3 }
Write-Host 'dialog closed'
