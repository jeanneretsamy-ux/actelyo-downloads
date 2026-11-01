param(
  [Parameter(Mandatory)] [string] $Id,
  [Parameter(Mandatory)] [string] $Urls,      # one or more URLs separated by ';' (multi-part = concatenated)
  [Parameter(Mandatory)] [string] $Sha256,
  [Parameter(Mandatory)] [string] $NamePattern, # wildcard matched against the uninstall DisplayName
  [int] $LaunchSeconds = 60
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

$out = Join-Path $env:GITHUB_WORKSPACE "qa-out/$Id"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$checks = [ordered]@{}
$facts = [ordered]@{ id = $Id }
function Check($name, [bool]$ok, $detail = '') {
  $checks[$name] = [ordered]@{ ok = $ok; detail = "$detail" }
  $mark = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Host "[$mark] $name $detail"
}
function Shot($file) {
  try {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $out $file), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  } catch { Write-Host "screenshot failed: $_" }
}
function UninstallEntries {
  $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
           'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $NamePattern }
}

# 1. Download + integrity
$installer = Join-Path $env:RUNNER_TEMP "$Id-setup.exe"
$parts = $Urls -split ';' | Where-Object { $_ }
$fs = [System.IO.File]::Create($installer)
foreach ($u in $parts) {
  $tmp = Join-Path $env:RUNNER_TEMP ([IO.Path]::GetFileName($u))
  & curl.exe -sSL --retry 3 -o $tmp $u
  $in = [System.IO.File]::OpenRead($tmp); $in.CopyTo($fs); $in.Dispose(); Remove-Item $tmp
}
$fs.Dispose()
$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
$facts.installerBytes = (Get-Item $installer).Length
Check 'sha256 matches catalog' ($hash -eq $Sha256.ToLower()) $hash
$sig = Get-AuthenticodeSignature $installer
$facts.installerSignature = "$($sig.Status)"
try { [System.Drawing.Icon]::ExtractAssociatedIcon($installer).ToBitmap().Save((Join-Path $out 'installer-icon.png')) } catch {}

# 2. Silent install
$before = @(UninstallEntries)
$facts.preExistingEntries = @($before | ForEach-Object { $_.DisplayName })
$log = Join-Path $out 'install.log'
$p = Start-Process $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/LOG=`"$log`"" -PassThru
if (-not $p.WaitForExit(1800 * 1000)) { $p.Kill(); Check 'installer finished within 30 min' $false } else { Check 'installer exit code 0' ($p.ExitCode -eq 0) "exit=$($p.ExitCode)" }
Shot '01-after-install.png'

$entry = @(UninstallEntries) | Select-Object -First 1
Check 'registered in Apps & features' ($null -ne $entry) "$($entry.DisplayName)"
if ($entry) {
  $facts.displayName    = $entry.DisplayName
  $facts.displayVersion = $entry.DisplayVersion
  $facts.publisher      = $entry.Publisher
  $facts.installLocation = $entry.InstallLocation
  $facts.displayIcon    = $entry.DisplayIcon
  $facts.uninstallString = $entry.UninstallString
  $facts.registryKey    = $entry.PSPath -replace '^.*::', ''
}

# 3. Locate the app executable + its icon
$appExe = $null
if ($entry.DisplayIcon) { $c = ($entry.DisplayIcon -split ',')[0].Trim('"'); if ((Test-Path $c) -and $c -like '*.exe' -and $c -notlike '*unins*') { $appExe = $c } }
$shortcuts = Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Windows\Start Menu", "$env:PUBLIC\Desktop", ([Environment]::GetFolderPath('Desktop')) -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-40) }
$wsh = New-Object -ComObject WScript.Shell
$facts.shortcuts = @($shortcuts | ForEach-Object { "$($_.FullName) -> $($wsh.CreateShortcut($_.FullName).TargetPath)" })
Check 'start menu / desktop shortcut created' ($shortcuts.Count -gt 0) "$($shortcuts.Count) shortcut(s)"
if (-not $appExe) {
  $t = $shortcuts | ForEach-Object { $wsh.CreateShortcut($_.FullName).TargetPath } | Where-Object { $_ -like '*.exe' -and $_ -notlike '*unins*' } | Select-Object -First 1
  if ($t) { $appExe = $t }
}
if (-not $appExe -and $entry.InstallLocation) {
  $appExe = (Get-ChildItem $entry.InstallLocation -Filter *.exe -ErrorAction SilentlyContinue | Where-Object Name -notlike 'unins*' | Sort-Object Length -Descending | Select-Object -First 1).FullName
}
$facts.appExe = $appExe
Check 'application executable present' ($appExe -and (Test-Path $appExe)) "$appExe"
if ($appExe -and (Test-Path $appExe)) {
  $vi = (Get-Item $appExe).VersionInfo
  $facts.appProductName = $vi.ProductName; $facts.appFileDescription = $vi.FileDescription; $facts.appProductVersion = $vi.ProductVersion; $facts.appCompany = $vi.CompanyName
  try { [System.Drawing.Icon]::ExtractAssociatedIcon($appExe).ToBitmap().Save((Join-Path $out 'app-icon.png')) } catch {}
  if ($entry.InstallLocation) {
    $ico = Get-ChildItem $entry.InstallLocation -Recurse -Include *.ico -ErrorAction SilentlyContinue | Select-Object -First 5
    $facts.icoFiles = @($ico | ForEach-Object FullName)
    $i = 0; foreach ($f in $ico) { try { (New-Object System.Drawing.Icon $f.FullName, 256, 256).ToBitmap().Save((Join-Path $out "ico-$i.png")); $i++ } catch {} }
  }
}

# 4. Launch + smoke
if ($appExe -and (Test-Path $appExe)) {
  $dir = Split-Path $appExe
  $proc = Start-Process $appExe -WorkingDirectory $dir -PassThru
  $alive = $true
  for ($s = 0; $s -lt $LaunchSeconds; $s += 5) {
    Start-Sleep 5
    if ($s -eq 15) { Shot '02-launch-15s.png' }
    $proc.Refresh()
    $fam = Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith($dir, 'OrdinalIgnoreCase') } catch { $false } }
    if (-not $fam) { $alive = $false; break }
  }
  Shot '03-launch-final.png'
  $fam = @(Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith($dir, 'OrdinalIgnoreCase') } catch { $false } })
  $titles = @($fam | Where-Object MainWindowTitle | ForEach-Object MainWindowTitle | Select-Object -Unique)
  $facts.processes = @($fam | ForEach-Object { "$($_.ProcessName)#$($_.Id) ws=$([int]($_.WorkingSet64/1MB))MB" })
  $facts.windowTitles = $titles
  $facts.listeningPorts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $fam.Id -contains $_.OwningProcess } | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" } | Select-Object -Unique)
  Check "app still running after ${LaunchSeconds}s" ($alive -and $fam.Count -gt 0) "$($fam.Count) process(es)"
  Check 'app opened a visible window' ($titles.Count -gt 0) ($titles -join ' | ')
  if (-not $proc.HasExited) { $exitInfo = 'running' } else { $exitInfo = "exited code=$($proc.ExitCode)" }
  $facts.mainProcess = $exitInfo
  $fam | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 5
  # crash dumps / logs the app may have written
  Get-ChildItem "$env:APPDATA", "$env:LOCALAPPDATA" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'actelyo|hermes|anythingllm|law' -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-40) } |
    ForEach-Object { $facts["userData:$($_.Name)"] = $_.FullName; Get-ChildItem $_.FullName -Recurse -Include *.log -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { Copy-Item $_.FullName (Join-Path $out ("applog-" + $_.Name)) -ErrorAction SilentlyContinue } }
}

# 5. Silent uninstall
if ($entry.UninstallString) {
  $u = ($entry.UninstallString -replace '"', '')
  $up = Start-Process $u -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -PassThru
  $null = $up.WaitForExit(600 * 1000)
  Start-Sleep 10
  Check 'uninstaller removes Apps & features entry' (-not (@(UninstallEntries) | Where-Object { $_.PSPath -eq $entry.PSPath })) ''
  if ($entry.InstallLocation) { Check 'uninstaller removes program files' (-not (Get-ChildItem $entry.InstallLocation -Recurse -Filter *.exe -ErrorAction SilentlyContinue)) $entry.InstallLocation }
}

$report = [ordered]@{ facts = $facts; checks = $checks; passed = -not ($checks.Values | Where-Object { -not $_.ok }) }
$report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'report.json') -Encoding utf8
"### $Id`n" + (($checks.GetEnumerator() | ForEach-Object { "- $(if ($_.Value.ok) {'✅'} else {'❌'}) $($_.Key) $($_.Value.detail)" }) -join "`n") | Add-Content $env:GITHUB_STEP_SUMMARY
if (-not $report.passed) { exit 1 }
