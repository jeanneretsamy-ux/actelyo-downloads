param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'suite/ActelyoSuite.psm1') -Force
$catalog=Read-SuiteJson (Join-Path $root 'catalog.json')
$items=@($catalog.items|Where-Object id -eq 'law-harness')
if($items.Count -ne 1 -or $items[0].version -notmatch '^2026\.\d+\.\d+$'){throw 'One frozen Law release required'}
$law=$items[0];Assert-SuiteItem $law
$out=[IO.Path]::GetFullPath($OutputDirectory)
$kit=Join-Path $out ('Actelyo-Law-Harness-'+$law.version)
if(Test-Path -LiteralPath $out){throw 'Use a fresh output directory'}
New-Item -ItemType Directory -Path $kit -Force|Out-Null
$encoding=New-Object Text.UTF8Encoding($true)
$script=[IO.File]::ReadAllText((Join-Path $root 'docs/Download-Actelyo.ps1'))
[IO.File]::WriteAllText((Join-Path $kit 'Download-Actelyo.ps1'),($script -replace '\r?\n',"`r`n"),$encoding)
Write-SuiteJson @{schemaVersion=1;revision=$catalog.revision;items=@($law)} (Join-Path $kit 'catalog.json')
$command="@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Download-Actelyo.ps1`" -UseBundledCatalog`r`nset `"result=%errorlevel%`"`r`npause`r`nexit /b %result%`r`n"
[IO.File]::WriteAllText((Join-Path $kit 'Telecharger.cmd'),$command,[Text.Encoding]::ASCII)
$guide="Actelyo Law Harness $($law.version)`r`n`r`nExtraire ce ZIP puis ouvrir Telecharger.cmd. Il télécharge seulement Law Harness, vérifie les parties et reconstitue l'EXE dans Paquets-Actelyo. Ouvrir ensuite cet EXE pour installer l'application. Le script n'installe rien automatiquement.`r`n`r`nLe catalogue fourni est figé pour cette version. Aucun modèle, clé API ou dossier privé n'est inclus. Prévoir l'espace pour l'EXE de 2,2 Go et l'application (réserve conseillée : 14 Go, plus les modèles).`r`n`r`nSHA-256 de l'EXE : $($law.sha256)`r`n"
[IO.File]::WriteAllText((Join-Path $kit 'LIRE-MOI.txt'),$guide,$encoding)
$file='Actelyo-Law-Harness-'+$law.version+'-Kit.zip'
$archive=Join-Path $out $file
Compress-Archive -Path (Join-Path $kit '*') -DestinationPath $archive
@{version=$law.version;file=$file;bytes=(Get-Item -LiteralPath $archive).Length;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();installerSha256=$law.sha256;installerBytes=$law.bytes;partCount=$law.parts.Count;onlyProduct='law-harness';automaticInstall=$false;bundledCatalogUsed=$true}|ConvertTo-Json|Set-Content (Join-Path $out 'kit-proof.json')
Write-Output $archive
