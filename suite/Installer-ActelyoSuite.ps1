[CmdletBinding()]
param(
    [ValidateSet('Plan','Download','Install','Verify')][string]$Mode='Plan',
    [string[]]$Apps=@('llm','rag-anything','rag','erp','openbousic','law-harness'),
    [string]$Destination='',
    [string]$ReportDirectory='',
    [switch]$IncludeTestModels,
    [string]$TestModelsCatalog='',
    [switch]$StartupOnly,
    [switch]$Accept,
    [switch]$SkipVerification
)
$ErrorActionPreference='Stop'
if (-not $Destination) { $Destination=Join-Path $PSScriptRoot 'Paquets-Actelyo' }
if (-not $ReportDirectory) { $ReportDirectory=Join-Path $PSScriptRoot ('Rapports/'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)) }
$Destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$ReportDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportDirectory)
Import-Module (Join-Path $PSScriptRoot 'ActelyoSuite.psm1') -Force
$report=[ordered]@{schemaVersion=1;startedAt=(Get-Date -Format o);mode=$Mode;status='running';steps=@();applications=@();interoperability='not-tested'}
New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportPath=Join-Path $ReportDirectory 'installation.json'
function Save-Report { Write-SuiteJson $report $reportPath }
try {
    if(-not $IncludeTestModels){$StartupOnly=$true}
    elseif($StartupOnly){throw 'Le diagnostic utilisateur et le profil QA interne ne peuvent pas etre combines.'}
    if ($Mode -eq 'Verify' -and $SkipVerification) { throw 'Verify ne peut pas ignorer la QA.' }
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Ce kit cible Windows x64.' }
    $suite=Read-SuiteJson (Join-Path $PSScriptRoot 'suite.json')
    $catalog=Read-SuiteJson (Join-Path $PSScriptRoot 'catalog.json')
    if ($suite.schemaVersion -ne 1 -or $catalog.schemaVersion -ne 1) { throw 'Format de kit inconnu.' }
    $Apps=@($Apps | Select-Object -Unique)
    if (-not $Apps.Count -or @($Apps | Where-Object {$_ -notin $suite.applications.id}).Count) { throw 'Selection d applications invalide.' }
    $definitions=@($suite.applications | Where-Object {$_.id -in $Apps})
    $ids=@($definitions.id)
    if ($IncludeTestModels) {
        if (-not $TestModelsCatalog) { throw 'Le profil QA interne exige un catalogue de reference explicite, absent du kit utilisateur.' }
        $testCatalog=Read-SuiteJson $TestModelsCatalog
        if($testCatalog.schemaVersion -ne 1 -or -not $testCatalog.items.Count){throw 'Catalogue QA invalide.'}
        $catalog.items+=@($testCatalog.items);$ids+=@($testCatalog.items.id)
    }
    $items=@(foreach ($id in $ids) {
        $matches=@($catalog.items | Where-Object {$_.id -eq $id})
        if ($matches.Count -ne 1) { throw ('Entree absente ou dupliquee : '+$id) }
        Assert-SuiteItem $matches[0]; $matches[0]
    })
    $report.catalogRevision=$catalog.revision
    $registrations=Get-SuiteRegistrations
    $pending=@()
    foreach ($definition in $definitions) {
        $item=$items | Where-Object {$_.id -eq $definition.id}
        $existing=Find-SuiteInstallation $definition $registrations
        $upToDate=$existing -and (Compare-SuiteVersion $existing.version $item.version) -ge 0
        $report.applications+=@{id=$definition.id;requestedVersion=$item.version;installed=$existing;action=$(if($upToDate){'keep'}else{'install'})}
        if (-not $upToDate) { $pending+= $definition }
    }
    $spaceDefinitions=if($Mode -eq 'Download'){@()}else{$pending}
    # A pre-existing file is either verified and reused or rejected, never overwritten.
    # It therefore requires no additional download space, including on an offline USB kit.
    $downloadItems=@($items | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $Destination $_.file)) -and
        ($Mode -ne 'Install' -or $_.category -ne 'desktop' -or $_.id -in @($pending.id))
    })
    $spaceInstallDirectory=if($Mode -eq 'Download'){''}else{Join-Path $env:LOCALAPPDATA 'Programs'}
    $report.space=@(Get-SuiteSpacePlan $downloadItems $spaceDefinitions $Destination $spaceInstallDirectory $suite.headroomGiB)
    foreach ($item in $items) { Write-Host ($item.name+' '+$item.version) }
    foreach ($space in $report.space) { Write-Host ('Disque '+$space.volume+' : '+[math]::Round($space.freeBytes/1GB,1)+' Gio libres / '+[math]::Ceiling($space.requiredBytes/1GB)+' Gio reserves') }
    if ($Mode -eq 'Plan') { $report.status='planned'; Save-Report; return }
    if ($Mode -in @('Install','Download') -and @($report.space | Where-Object {-not $_.ok}).Count) { throw 'Espace insuffisant. Aucun installateur ne sera lance. Le dossier de telechargement peut etre choisi sur un autre disque avec -Destination ; les applications utilisent leur dossier Windows habituel.' }
    if ($Mode -eq 'Install' -and -not $Accept) {
        if ((Read-Host 'Installer cette selection, sans desinstaller les autres applications ni effacer leurs donnees ? (O/N)') -notmatch '^[oOyY]$') { throw 'Installation annulee.' }
    }
    if ($Mode -in @('Download','Install')) {
        foreach ($item in $items) {
            $definition=$definitions | Where-Object {$_.id -eq $item.id}
            if ($Mode -eq 'Install' -and $definition -and $definition.id -notin @($pending.id)) { continue }
            $download=Receive-SuiteItem $item $Destination
            $report.steps+=@{id=$item.id;step='download';status='pass';sha256=$item.sha256}; Save-Report
            if ($Mode -ne 'Install' -or $item.category -ne 'desktop') { continue }
            $existing=Find-SuiteInstallation $definition (Get-SuiteRegistrations)
            if ($existing) {
                $prefix=$existing.directory.TrimEnd('\')+'\'
                $running=@(Get-Process | Where-Object {try {$_.Path -and $_.Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)} catch {$false}})
                if ($running.Count) { throw ('Fermez '+$item.name+' avant sa mise a jour.') }
            }
            # Re-check disk before every installer; download size is already reserved separately.
            $remaining=@($pending | Where-Object {$_.id -notin @($report.steps | Where-Object {$_.step -eq 'install' -and $_.status -eq 'pass'} | ForEach-Object {$_.id})})
            $spaceNow=@(Get-SuiteSpacePlan @() $remaining $Destination (Join-Path $env:LOCALAPPDATA 'Programs') $suite.headroomGiB)
            if (@($spaceNow | Where-Object {-not $_.ok}).Count) { throw 'Espace devenu insuffisant avant installation. Installation suspendue.' }
            $log=Join-Path ([IO.Path]::GetFullPath($ReportDirectory)) ($item.id+'-install.log')
            $process=Start-Process -FilePath $download -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/LOG="'+$log+'"')) -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw ('Echec de '+$item.id+' : code '+$process.ExitCode+'. Voir '+$log) }
            $installed=Find-SuiteInstallation $definition (Get-SuiteRegistrations)
            if (-not $installed -or (Compare-SuiteVersion $installed.version $item.version) -lt 0) { throw ('Version installee non confirmee : '+$item.id) }
            $report.steps+=@{id=$item.id;step='install';status='pass';version=$installed.version}; Save-Report
        }
    }
    $installedApps=@(foreach ($definition in $definitions) {
        $installed=Find-SuiteInstallation $definition (Get-SuiteRegistrations)
        if (-not $installed -and $Mode -ne 'Download') { throw ('Application absente : '+$definition.id) }
        if ($installed) { $installed }
    })
    Write-SuiteJson @{schemaVersion=1;applications=$installedApps;modelsDirectory=[IO.Path]::GetFullPath($Destination);catalog=$catalog;reportDirectory=[IO.Path]::GetFullPath($ReportDirectory)} (Join-Path $ReportDirectory 'installed.json')
    if ($Mode -in @('Install','Verify') -and -not $SkipVerification) {
        $nodeOwner=$installedApps | Where-Object {$_.id -eq 'openbousic'}
        if (-not $nodeOwner) { throw 'La QA complete requiert OpenBousic et son moteur Node integre. Choisissez Download ou installez OpenBousic.' }
        $node=Join-Path $nodeOwner.directory 'resources/node/node.exe'
        if (-not (Test-Path -LiteralPath $node)) { throw 'Moteur Node integre absent.' }
        if (-not (Test-Path (Join-Path $PSScriptRoot 'qa/runtime/node_modules/playwright-core/package.json'))) { throw 'Runtime QA absent. Utilisez le ZIP complet du kit.' }
        $qaArguments=@((Join-Path $PSScriptRoot 'qa/suite.mjs'),(Join-Path $ReportDirectory 'installed.json'))
        if($StartupOnly){$qaArguments+='--startup-only'}
        & $node @qaArguments
        if ($LASTEXITCODE -ne 0) { throw ('QA non validee. Voir '+(Join-Path $ReportDirectory 'qa.json')) }
        if($StartupOnly){$report.interoperability='not-tested';$report.startup='pass'}else{$report.interoperability='pass'}
    }
    $report.status=if($Mode -eq 'Download'){'downloaded'}elseif($SkipVerification){'installed'}elseif($StartupOnly){'startup-pass'}else{'pass'}
} catch {
    $report.status='fail'; $report.error=$_.Exception.Message
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
} finally { $report.finishedAt=(Get-Date -Format o); Save-Report; Write-Host ('Rapport : '+$reportPath) }
