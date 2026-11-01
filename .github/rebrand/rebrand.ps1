param(
  [Parameter(Mandatory)] [string] $Id,
  [Parameter(Mandatory)] [string] $Urls,          # ';'-separated parts of the verified source installer
  [Parameter(Mandatory)] [string] $Sha256,
  [Parameter(Mandatory)] [string] $NamePattern,   # uninstall DisplayName of the source installer
  [Parameter(Mandatory)] [string] $AppName,
  [Parameter(Mandatory)] [string] $ExeName,
  [Parameter(Mandatory)] [string] $DirName,
  [Parameter(Mandatory)] [string] $ShortcutName,
  [Parameter(Mandatory)] [string] $Version,
  [Parameter(Mandatory)] [string] $OutputBase,
  [Parameter(Mandatory)] [string] $Icon
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
$out = Join-Path $env:GITHUB_WORKSPACE "out/$Id"; New-Item -ItemType Directory -Force $out | Out-Null
$proof = Join-Path $out 'proof'; New-Item -ItemType Directory -Force $proof | Out-Null
$Icon = (Resolve-Path $Icon).Path
function Shot($file) {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
  $small = New-Object System.Drawing.Bitmap $bmp, ([int]($b.Width / 2)), ([int]($b.Height / 2))
  $small.Save((Join-Path $proof $file), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); $small.Dispose()
}
function Entries {
  Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like $NamePattern }
}
function SaveIcon($path, $png) { [System.Drawing.Icon]::ExtractAssociatedIcon($path).ToBitmap().Save((Join-Path $proof $png)) }

# 1. Verified source installer
$src = Join-Path $env:RUNNER_TEMP "$Id-source.exe"
$fs = [IO.File]::Create($src)
foreach ($u in ($Urls -split ';' | Where-Object { $_ })) {
  $part = Join-Path $env:RUNNER_TEMP 'part.bin'
  & curl.exe -fsSL --retry 3 -o $part $u; if ($LASTEXITCODE) { throw "download failed: $u" }
  $in = [IO.File]::OpenRead($part); $in.CopyTo($fs); $in.Dispose(); Remove-Item $part
}
$fs.Dispose()
if ((Get-FileHash $src -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) { throw 'source installer hash mismatch' }

# 2. Install it to a short path (deep Python paths), read its AppId
$stage = "C:\s\$Id"
$p = Start-Process $src -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOICONS',"/DIR=`"$stage`"" -Wait -PassThru
if ($p.ExitCode) { throw "source install failed: $($p.ExitCode)" }
$entry = @(Entries)[0]; if (-not $entry) { throw 'source install not registered' }
$appId = ($entry.PSChildName -replace '_is1$', '')
if ($appId -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw "unexpected AppId $appId" }
Write-Host "Source: $($entry.DisplayName) $($entry.DisplayVersion) AppId=$appId"
$exe = Join-Path $stage $ExeName; if (-not (Test-Path $exe)) { throw "missing $exe" }
SaveIcon $exe 'before-app-icon.png'

# 3. Copy the application, uninstall the source, stamp the logo + version on the exe
$app = "C:\p\$Id"
& robocopy $stage $app /E /XF 'unins*.exe' 'unins*.dat' 'unins*.msg' /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed $LASTEXITCODE" }
$u = Start-Process ($entry.UninstallString -replace '"', '') -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
Start-Sleep 5
$rcedit = Join-Path $env:RUNNER_TEMP 'rcedit-x64.exe'
& curl.exe -fsSL --retry 3 -o $rcedit 'https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe'
if ((Get-FileHash $rcedit -Algorithm SHA256).Hash -ne '3E7801DB1A5EDBEC91B49A24A094AAD776CB4515488EA5A4CA2289C400EADE2A') { throw 'rcedit hash mismatch' }
$appExe = Join-Path $app $ExeName
& $rcedit $appExe --set-icon $Icon --set-product-version $Version --set-file-version $Version --set-version-string ProductName $AppName --set-version-string FileDescription $AppName --set-version-string CompanyName 'Actelyo'
if ($LASTEXITCODE) { throw 'rcedit failed' }

# 4. Compile with pinned, signature-checked Inno Setup 7 (handles long paths and > 2 GB setups)
$inno = Join-Path $env:RUNNER_TEMP 'innosetup-7.1.0-x64.exe'
Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe' -OutFile $inno
$sig = Get-AuthenticodeSignature $inno
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') { throw 'Inno Setup signature check failed' }
$innoRoot = Join-Path $env:RUNNER_TEMP 'Inno7'
$ip = Start-Process $inno -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$innoRoot" -Wait -PassThru
if ($ip.ExitCode) { throw 'Inno Setup install failed' }
$iss = Join-Path $env:GITHUB_WORKSPACE '.github/rebrand/installer.iss'
& (Join-Path $innoRoot 'ISCC.exe') "/DAppSource=$app" "/DAppId={$appId" "/DAppName=$AppName" "/DAppVersion=$Version" "/DDirName=$DirName" "/DExeName=$ExeName" "/DShortcutName=$ShortcutName" "/DOutputDir=$out" "/DOutputBase=$OutputBase" "/DAppIcon=$Icon" $iss
if ($LASTEXITCODE) { throw 'ISCC failed' }
$setup = Join-Path $out "$OutputBase.exe"
Remove-Item -Recurse -Force $app
SaveIcon $setup 'installer-icon.png'

# 5. QA: fresh install, shortcuts, icon, launch, window
$p = Start-Process $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/LOG=`"$out\install.log`"" -Wait -PassThru
if ($p.ExitCode) { throw "new installer failed: $($p.ExitCode)" }
$e = @(Entries)[0]; if (-not $e) { throw 'new install not registered' }
if ($e.PSChildName -ne "${appId}_is1") { throw 'AppId changed: upgrade would not replace the old version' }
if ($e.DisplayVersion -ne $Version) { throw "DisplayVersion $($e.DisplayVersion)" }
$installed = $e.InstallLocation.TrimEnd('\')
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$ShortcutName.lnk"
if (-not (Test-Path $lnk)) { throw "desktop shortcut missing: $lnk" }
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
SaveIcon (Join-Path $installed $ExeName) 'after-app-icon.png'
$proc = Start-Process (Join-Path $installed $ExeName) -WorkingDirectory $installed -PassThru
Start-Sleep 75
Shot 'app-running.png'
$fam = @(Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith($installed, 'OrdinalIgnoreCase') } catch { $false } })
$titles = @($fam | Where-Object MainWindowTitle | ForEach-Object MainWindowTitle | Select-Object -Unique)
$fam | Stop-Process -Force -ErrorAction SilentlyContinue
$vi = (Get-Item (Join-Path $installed $ExeName)).VersionInfo
$report = [ordered]@{ id = $Id; appId = $appId; displayName = $e.DisplayName; displayVersion = $e.DisplayVersion; installLocation = $installed
  shortcut = $lnk; shortcutTarget = $sc.TargetPath; shortcutIcon = $sc.IconLocation; exeProductName = $vi.ProductName; exeVersion = $vi.ProductVersion
  processes = $fam.Count; windowTitles = $titles; sourceDisplayName = $entry.DisplayName; sourceVersion = $entry.DisplayVersion }
$report | ConvertTo-Json | Set-Content (Join-Path $proof 'report.json') -Encoding utf8
Write-Host ($report | ConvertTo-Json)
if ($fam.Count -eq 0 -or $titles.Count -eq 0) { throw 'application did not open a window' }

# 6. Checksums (+ < 2 GB parts for GitHub release assets)
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower()
"$hash  $OutputBase.exe" | Set-Content (Join-Path $out 'SHA256SUMS.txt')
$len = (Get-Item $setup).Length
"SETUP_BYTES=$len" >> $env:GITHUB_ENV; "SETUP_SHA256=$hash" >> $env:GITHUB_ENV
if ($len -gt 1900000000) {
  $buf = New-Object byte[] (8MB); $in = [IO.File]::OpenRead($setup); $n = 1
  while ($in.Position -lt $len) {
    $pp = Join-Path $out ("$OutputBase.exe.part{0:D2}" -f $n); $o = [IO.File]::Create($pp); $w = 0
    while ($w -lt 1000000000 -and ($r = $in.Read($buf, 0, [Math]::Min($buf.Length, 1000000000 - $w))) -gt 0) { $o.Write($buf, 0, $r); $w += $r }
    $o.Dispose(); $n++
  }
  $in.Dispose(); Remove-Item $setup
  Get-ChildItem $out -Filter '*.part*' | ForEach-Object { "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())  $($_.Name)" } | Add-Content (Join-Path $out 'SHA256SUMS.txt')
}
Get-ChildItem $out | Format-Table Name, Length
