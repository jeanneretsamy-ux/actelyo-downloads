<#
  ACTELYO — remplace les anciennes versions par les nouvelles, avec les logos.

  Lancer dans PowerShell (pas besoin d'être administrateur) :
      powershell -ExecutionPolicy Bypass -File .\Installer-Actelyo-Logos.ps1

  Ce que fait le script :
    1. Liste les applications Actelyo installées.
    2. Désinstalle les anciennes applications qui ne font plus partie de la gamme
       (ex. Actelyo LLMQushu, ancien « Actelyo » 1.0.x), après votre confirmation.
    3. Télécharge les 5 nouveaux installateurs, vérifie leur SHA-256 et les installe.
       Ils remplacent automatiquement les anciennes versions (même identifiant d'application).
    4. Rafraîchit le cache des icônes Windows pour afficher les nouveaux logos.

  Vos données (dossiers, conversations, modèles, %APPDATA%) ne sont pas supprimées.
#>
$ErrorActionPreference = 'Stop'
$base = 'https://github.com/jeanneretsamy-ux/actelyo-downloads/releases/download'
$produits = @(
  @{ Nom = 'Actelyo ERP Desktop';  Motif = '^Actelyo ERP';         Version = '1.8.2'
     Parties = @("$base/desktop-erp-v1.8.2/Actelyo-ERP-Desktop-Setup-1.8.2-x64.exe")
     Sha256 = 'dad4952a22729e3943efe86357b8e500b6764f51ae459f2862c8e9d1711fd97a' },
  @{ Nom = 'Actelyo LLM Studio';   Motif = '^Actelyo LLM Desktop'; Version = '3.0.3'
     Parties = @("$base/desktop-llm-v3.0.3/Actelyo-LLM-Desktop-Setup-3.0.3-x64.exe")
     Sha256 = '904290a09bd873d4f57efdbe5c0baa7d673c36bc727a0bd9d2fd9a770429ab8d' },
  @{ Nom = 'Actelyo RAG Desktop';  Motif = '^Actelyo RAG Desktop'; Version = '1.0.4'
     Parties = @("https://github.com/jeanneretsamy-ux/anything-llmACTELYO/releases/download/actelyo-rag-desktop-v1.0.4/Actelyo-RAG-Desktop-Setup-1.0.4-x64.exe")
     Sha256 = '83ea7d61e9ee6b52bca7c7e913007d515d220ff0fbf2620124e20d1dd1121094' },
  @{ Nom = 'Actelyo Law Harness';  Motif = '^Actelyo Law Harness'; Version = '2026.11.2'
     Parties = @("https://github.com/jeanneretsamy-ux/hermes-agentactelyo/releases/download/desktop-law-v2026.11.2/Actelyo-Law-Harness-Setup-2026.11.2-x64.exe.part01",
                 "https://github.com/jeanneretsamy-ux/hermes-agentactelyo/releases/download/desktop-law-v2026.11.2/Actelyo-Law-Harness-Setup-2026.11.2-x64.exe.part02",
                 "https://github.com/jeanneretsamy-ux/hermes-agentactelyo/releases/download/desktop-law-v2026.11.2/Actelyo-Law-Harness-Setup-2026.11.2-x64.exe.part03")
     Sha256 = '3a0f43ac3152eb6fa785eb99f5a799010910d54c17e735d8f77f223ca1073ad1' },
  @{ Nom = 'Actelyo OpenBousic';   Motif = '^Actelyo OpenBousic';  Version = '2.0.161'
     Parties = @("$base/desktop-openbousic-v2.0.161/Actelyo-OpenBousic-Setup-2.0.161-x64.exe")
     Sha256 = 'd30a0ffddbb0af3f90e54d2661b07d320b45c8c86e0a5b9bb487ef7ee4651607' }
)
# Applications Actelyo à conserver même si elles ne sont pas dans la liste ci-dessus
$aConserver = '^Actelyo RAG-Anything'

$cles = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
function Installees { Get-ItemProperty $cles -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^(Actelyo|Hermes)' -and $_.UninstallString } }
function Arreter($dossier) {
  if ($dossier -and (Test-Path $dossier)) {
    Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith($dossier, 'OrdinalIgnoreCase') } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "`n=== Applications Actelyo installées ===" -ForegroundColor Cyan
$avant = @(Installees)
if (-not $avant) { Write-Host '(aucune)' }
$anciennes = @()
foreach ($a in $avant) {
  $p = $produits | Where-Object { $a.DisplayName -match $_.Motif } | Select-Object -First 1
  if ($p) { $etat = "sera mise à jour en $($p.Version)"; $c = 'Yellow' }
  elseif ($a.DisplayName -match $aConserver) { $etat = 'conservée'; $c = 'Green' }
  else { $etat = 'ANCIENNE, à désinstaller'; $c = 'Red'; $anciennes += $a }
  Write-Host ("  {0}  v{1}  -> {2}" -f $a.DisplayName, $a.DisplayVersion, $etat) -ForegroundColor $c
}

if ($anciennes) {
  $r = Read-Host "`nDésinstaller les $($anciennes.Count) ancienne(s) application(s) en rouge ? (O/N)"
  if ($r -match '^[oOyY]') {
    foreach ($a in $anciennes) {
      Write-Host "Désinstallation : $($a.DisplayName)" -ForegroundColor Cyan
      Arreter $a.InstallLocation
      $cmd = if ($a.QuietUninstallString) { $a.QuietUninstallString } else { $a.UninstallString }
      if ($cmd -match 'msiexec') { Start-Process msiexec.exe -ArgumentList "/x $([regex]::Match($cmd,'\{[0-9A-Fa-f\-]+\}').Value) /qn /norestart" -Wait }
      else {
        $m = [regex]::Match($cmd, '^\s*"([^"]+)"\s*(.*)$')
        if ($m.Success) { $exe = $m.Groups[1].Value; $arg = $m.Groups[2].Value } else { $exe = ($cmd -split ' (?=/)')[0]; $arg = $cmd.Substring($exe.Length) }
        if (-not $a.QuietUninstallString) { $arg += $(if ($exe -match 'unins\d*\.exe$') { ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } else { ' /S' }) }
        try { Start-Process $exe -ArgumentList $arg.Trim() -Wait } catch { Write-Host "  Échec : $_  -> désinstallez-la depuis Paramètres > Applications." -ForegroundColor Red }
      }
    }
  }
}

$tmp = Join-Path $env:TEMP 'actelyo-logos'; New-Item -ItemType Directory -Force $tmp | Out-Null
foreach ($p in $produits) {
  Write-Host "`n=== $($p.Nom) $($p.Version) ===" -ForegroundColor Cyan
  $setup = Join-Path $tmp ("{0}-{1}.exe" -f ($p.Nom -replace ' ', '-'), $p.Version)
  if (-not ((Test-Path $setup) -and (Get-FileHash $setup -Algorithm SHA256).Hash -eq $p.Sha256.ToUpper())) {
    $out = [IO.File]::Create($setup)
    try {
      foreach ($u in $p.Parties) {
        Write-Host "  Téléchargement $([IO.Path]::GetFileName($u)) ..."
        $part = "$setup.part"; & curl.exe -fL --retry 3 -o $part $u
        if ($LASTEXITCODE) { throw "Téléchargement impossible : $u" }
        $in = [IO.File]::OpenRead($part); $in.CopyTo($out); $in.Dispose(); Remove-Item $part
      }
    } finally { $out.Dispose() }
  }
  if ((Get-FileHash $setup -Algorithm SHA256).Hash -ne $p.Sha256.ToUpper()) { Write-Host '  Fichier corrompu (SHA-256 différent) : installation annulée.' -ForegroundColor Red; continue }
  Write-Host '  SHA-256 vérifié. Installation...'
  Installees | Where-Object { $_.DisplayName -match $p.Motif } | ForEach-Object { Arreter $_.InstallLocation }
  $proc = Start-Process $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
  $ok = Installees | Where-Object { $_.DisplayName -match $p.Motif -and $_.DisplayVersion -eq $p.Version }
  if ($proc.ExitCode -eq 0 -and $ok) { Write-Host "  OK : $($ok.DisplayName)" -ForegroundColor Green; Remove-Item $setup -ErrorAction SilentlyContinue }
  else { Write-Host "  Échec (code $($proc.ExitCode)). L'installateur reste dans $setup" -ForegroundColor Red }
}

# Les anciennes icônes restent en cache : on vide le cache et on relance l'Explorateur.
Write-Host "`nRafraîchissement des icônes..." -ForegroundColor Cyan
& ie4uinit.exe -show 2>$null
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep 2
Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Force -ErrorAction SilentlyContinue
Start-Process explorer.exe

Write-Host "`n=== Résultat ===" -ForegroundColor Cyan
Installees | Sort-Object DisplayName | ForEach-Object { Write-Host ("  {0}  v{1}" -f $_.DisplayName, $_.DisplayVersion) }
Write-Host "`nTerminé. Vos données n'ont pas été touchées." -ForegroundColor Green
