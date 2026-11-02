# Full-desktop screenshot. -Maximize first maximizes and focuses the "Actelyo LLM" window.
param([string] $Path, [switch] $Maximize)
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
if ($Maximize) {
  Add-Type -Namespace QA -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
  $w = Get-Process | Where-Object { $_.MainWindowTitle -eq 'Actelyo LLM' } | Select-Object -First 1
  if ($w) { [QA.Win]::ShowWindow($w.MainWindowHandle, 3) | Out-Null; [QA.Win]::SetForegroundWindow($w.MainWindowHandle) | Out-Null; Write-Host "maximized $($w.Id)" }
}
if ($Path) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
