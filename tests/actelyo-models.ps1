$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'suite/ActelyoSuite.psm1') -Force
$catalog=Read-SuiteJson (Join-Path $root 'catalog.json')
$models=@($catalog.items|Where-Object {$_.category -eq 'model'})
if($models.Count -ne 4 -or @($models|Where-Object {$_.publisher -ne 'Actelyo'}).Count){throw 'Only the four actual Actelyo model identities may be offered.'}
foreach($model in ($models|Where-Object {$_.PSObject.Properties['modelSource']})) {
    if($model.PSObject.Properties['url'] -or $model.access -ne 'huggingface-private' -or $model.modelSource.repository -notmatch '^DActelyo/' -or $model.modelSource.revision -notmatch '^[a-f0-9]{40}$'){throw 'Private model must not appear as anonymous download.'}
    $total=0
    foreach($file in $model.modelSource.files){if($file.sha256 -notmatch '^[a-f0-9]{64}$' -or $file.bytes -le 0){throw 'Missing model file receipt.'};$total+=$file.bytes}
    if($total -ne $model.bytes){throw 'Snapshot size differs.'}
}
if(($models|Where-Object {$_.id -eq 'matousse-decision'}).PSObject.Properties['modelSource']){throw 'Unvalidated candidate must not be auto-installed.'}
$launcher=[IO.File]::ReadAllText((Join-Path $root 'suite/Installer.cmd'))
if($launcher -match 'IncludeTestModels' -or $launcher -notmatch 'Installer-ModelesActelyo.ps1'){throw 'User launcher must not download generic QA models.'}
& (Join-Path $root 'suite/Installer-ModelesActelyo.ps1') -Mode Plan -Models legalya-v36-r2,qushu-embed
$rejected=$false
try { & (Join-Path $root 'suite/Installer-ModelesActelyo.ps1') -Mode Plan -Models qwen-small } catch {$rejected=$true}
if(-not $rejected){throw 'Non-Actelyo model was selectable.'}
$rejected=$false
try { & (Join-Path $root 'suite/Installer-ModelesActelyo.ps1') -Mode Plan -Models matousse-decision } catch {$rejected=$true}
if(-not $rejected){throw 'Experimental model was selectable.'}
# Exercise the real downloader cache, including the authenticated code path,
# without sending a credential or fixture to a remote service.
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('actelyo-model-policy-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $tmp|Out-Null
$file=Join-Path $tmp 'fixture.gguf';[IO.File]::WriteAllText($file,'private model integrity fixture')
$item=[pscustomobject]@{id='actelyo-fixture';name='Fixture';file='fixture.gguf';url='https://huggingface.co/DActelyo/test/resolve/pinned/fixture.gguf';bytes=(Get-Item $file).Length;sha256=(Get-FileHash $file).Hash}
$token=ConvertTo-SecureString 'local-fixture-never-sent' -AsPlainText -Force
if((Receive-SuiteItem $item $tmp $token) -ne $file){throw 'Offline verified cache was not reused.'}
[IO.File]::WriteAllText($file,'corrupt')
$rejected=$false;try{Receive-SuiteItem $item $tmp $token|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Corrupt model cache was accepted.'}
Write-Host 'PASS Actelyo-only selection, private snapshots, experimental exclusion and verified offline cache'
