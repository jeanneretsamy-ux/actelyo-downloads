$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Synthetic GitHub runner required'}
$out=Join-Path $env:GITHUB_WORKSPACE 'erp-repack'
New-Item -ItemType Directory -Path $out | Out-Null
$stage=Join-Path $env:RUNNER_TEMP 'erp-approved-source'
$app=Join-Path $env:RUNNER_TEMP 'erp-approved-payload'
$legacy=Join-Path $env:RUNNER_TEMP 'erp-legacy-install'
$source=Join-Path $env:RUNNER_TEMP 'erp-approved.exe'
function Download([string]$Url,[string]$File,[string]$Hash){
  Invoke-WebRequest -Uri $Url -UseBasicParsing -OutFile $File
  if((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Hash){throw 'Public input SHA-256 mismatch'}
}
function Entries {
  @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -like 'Actelyo ERP*'})
}
function Run([string]$File,[string[]]$Arguments){
  $p=Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
  if($p.ExitCode -ne 0){throw ('Installer exit '+$p.ExitCode)}
}
$approved='8D7AC703E1F614BEDFA8B390D3F68D04412B229F32E13D6947E3A6099A7E46CE'
Download 'https://github.com/jeanneretsamy-ux/actelyo-downloads/releases/download/desktop-erp-v1.8.6-rc.4/Actelyo-ERP-Desktop-Setup-1.8.6-rc.4-x64.exe' $source $approved
if((Entries).Count){throw 'Runner already contains ERP'}
# The source NSIS System.dll crashes on current hosted Windows. Extract its
# signed-off application archive without executing the NSIS bootstrapper.
$seven=Join-Path $env:ProgramFiles '7-Zip/7z.exe'
if(-not(Test-Path -LiteralPath $seven)){throw 'Runner 7-Zip missing'}
& $seven x -y ('-o'+$stage) $source
if($LASTEXITCODE -ne 0){throw 'Cannot extract approved NSIS archive'}
$archives=@(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter 'app-64.7z')
if($archives.Count -ne 1){throw 'Expected one x64 application payload'}
& $seven x -y ('-o'+$app) $archives[0].FullName
if($LASTEXITCODE -ne 0){throw 'Cannot extract approved application payload'}
$nsisKey='06c02639-d5eb-5f4c-955b-28bf5988495d'
$exe=Join-Path $app 'Actelyo ERP.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Approved application missing'}
if((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -notmatch '^1\.8\.6'){throw 'Wrong approved executable version'}
$files=@(Get-ChildItem -LiteralPath $app -File -Recurse -Force | ForEach-Object {@{path=$_.FullName.Substring($app.Length+1);bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
$asar=(Get-FileHash -LiteralPath (Join-Path $app 'resources/app.asar') -Algorithm SHA256).Hash.ToLowerInvariant()
if($asar -ne 'ddf79a06f947978ce85a135dbcd9e9430d6fa2914728d4af1e2b68cae0c53909'){throw 'ASAR differs from the locally installed and qualified rc4'}
$files | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'approved-payload-files.json')
$inno=Join-Path $env:RUNNER_TEMP 'inno7.exe'
Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe' -OutFile $inno
$sig=Get-AuthenticodeSignature -FilePath $inno
if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {throw 'Inno signature verification failed'}
$compiler=Join-Path $env:RUNNER_TEMP 'Inno7'
Run $inno @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR='+$compiler))
$icon=(Resolve-Path '.github/branding/actelyo-erp.ico').Path
& (Join-Path $compiler 'ISCC.exe') "/DAppSource=$app" "/DOutputDir=$out" "/DAppIcon=$icon" "/DNsisKey=$nsisKey" '.github/rebrand/erp-public.iss'
if($LASTEXITCODE -ne 0){throw 'ERP wrapper compilation failed'}
$setup=Join-Path $out 'Actelyo-ERP-Desktop-Setup-1.8.6-rc.4-r2-x64.exe'
$old=Join-Path $env:RUNNER_TEMP 'erp-legacy.exe'
Download 'https://github.com/jeanneretsamy-ux/actelyo-downloads/releases/download/desktop-erp-v1.8.2/Actelyo-ERP-Desktop-Setup-1.8.2-x64.exe' $old 'DAD4952A22729E3943EFE86357B8E500B6764F51AE459F2862C8E9D1711FD97A'
Run $old @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="'+$legacy+'"'))
$oldEntries=Entries
if($oldEntries.Count -ne 1 -or $oldEntries[0].PSChildName -ne '{798C7D34-BB9C-47E6-B12D-A621C9D36B73}_is1'){throw 'Legacy installer identity differs'}
$profile=Join-Path $env:APPDATA 'actelyo-erp'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$sentinel=Join-Path $profile 'installer-qa-preserve.txt'
[IO.File]::WriteAllText($sentinel,'Synthetic persistent ERP profile — preserve during upgrade.')
$sentinelHash=(Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
# No /DIR: the retained legacy identity must recover its real existing location.
Run $setup @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOCLOSEAPPLICATIONS','/SP-',('/LOG="'+(Join-Path $out 'upgrade.log')+'"'))
$installed=Entries
if($installed.Count -ne 1 -or $installed[0].DisplayVersion -ne '1.8.6-rc.4' -or $installed[0].InstallLocation.TrimEnd('\') -ne $legacy.TrimEnd('\')){throw 'Upgrade created a duplicate or changed the existing installation directory'}
if((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -ne $sentinelHash){throw 'Persistent profile changed during installation'}
foreach($file in $files){$target=Join-Path $legacy $file.path;if(-not(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.sha256){throw ('Approved payload changed: '+$file.path)}}
$hash=(Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
@{version='1.8.6-rc.4';packagingRevision=2;file=(Split-Path $setup -Leaf);bytes=(Get-Item -LiteralPath $setup).Length;sha256=$hash;sourceInstallerSha256=$approved.ToLowerInvariant();publicPayloadUnchanged=$true;applicationAsarSha256=$asar;payloadFileCount=$files.Count;legacyVersion='1.8.2';upgradeVerified=$true;singleRegistration=$true;existingDirectoryPreserved=$true;profileSentinelPreserved=$true;appId='{798C7D34-BB9C-47E6-B12D-A621C9D36B73}';sourceCommit=$env:GITHUB_SHA} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'build-manifest.json')
"$hash  $(Split-Path $setup -Leaf)" | Set-Content (Join-Path $out 'SHA256SUMS.txt')
"ERP_REPACK_EXE=$(Join-Path $legacy 'Actelyo ERP.exe')" >> $env:GITHUB_ENV
