[CmdletBinding()]
param([ValidateSet('Plan','Download')][string]$Mode='Download',[string[]]$Models=@(),[string]$Destination='',[Security.SecureString]$HuggingFaceToken=$null)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ActelyoSuite.psm1') -Force
if(-not $Destination){$Destination=Join-Path $PSScriptRoot 'Paquets-Actelyo/Modeles'}
$Destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$catalogPath=Join-Path $PSScriptRoot 'catalog.json'
if(-not(Test-Path -LiteralPath $catalogPath)){$catalogPath=Join-Path $PSScriptRoot '../catalog.json'}
$catalog=Read-SuiteJson $catalogPath
$available=@($catalog.items|Where-Object {$_.category -eq 'model' -and $_.publisher -eq 'Actelyo' -and $_.PSObject.Properties['modelSource']})
if(-not $Models.Count) {
    Write-Host 'Modeles Actelyo :'
    for($i=0;$i -lt $available.Count;$i++){Write-Host (($i+1).ToString()+'. '+$available[$i].name+' - '+[math]::Round($available[$i].bytes/1GB,2)+' Gio - '+$available[$i].platform)}
    Write-Host 'Matousse Decision : candidat experimental ; installation automatique non proposee.'
    if($Mode -eq 'Plan'){return}
    $answer=Read-Host 'Numeros separes par des virgules, ou Entree pour plus tard'
    if(-not $answer.Trim()){return}
    $Models=@(foreach($number in $answer.Split(',')){
        if($number.Trim() -notmatch '^\d+$' -or [int]$number -lt 1 -or [int]$number -gt $available.Count){throw 'Selection de modeles invalide.'}
        $available[[int]$number-1].id
    })
}
$selected=@(foreach($id in ($Models|Select-Object -Unique)){
    $matches=@($available|Where-Object {$_.id -eq $id});if($matches.Count -ne 1){throw ('Modele Actelyo non installable : '+$id)};$matches[0]
})
$downloads=@(foreach($model in $selected){
    $source=$model.modelSource
    if($source.repository -notmatch '^DActelyo/[a-zA-Z0-9_.-]+$' -or $source.revision -notmatch '^[a-f0-9]{40}$' -or -not $source.files.Count){throw 'Origine Actelyo invalide.'}
    foreach($file in $source.files){
        if($file.file -notmatch '^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$' -or @($file.file.Split('/')|Where-Object {$_ -in @('.','..')}).Count){throw 'Chemin de modele invalide.'}
        $url='https://huggingface.co/'+$source.repository+'/resolve/'+$source.revision+'/'+$file.file
        $item=[pscustomobject]@{id=$model.id;name=$model.name;file=[IO.Path]::GetFileName($file.file);url=$url;bytes=$file.bytes;sha256=$file.sha256}
        Assert-SuiteItem $item
        $relative=($model.id+'/'+$file.file).Replace('/',[IO.Path]::DirectorySeparatorChar)
        [pscustomobject]@{item=$item;path=(Join-Path $Destination $relative);model=$model.id}
    }
})
$remaining=@($downloads|Where-Object {-not(Test-Path -LiteralPath $_.path)}|ForEach-Object {$_.item})
$space=@(Get-SuiteSpacePlan $remaining @() $Destination '' 1)
foreach($m in $selected){Write-Host ($m.name+' : '+$m.note)}
foreach($s in $space){Write-Host ('Espace reserve : '+[math]::Ceiling($s.requiredBytes/1GB)+' Gio ; disponible : '+[math]::Floor($s.freeBytes/1GB)+' Gio')}
if($Mode -eq 'Plan'){return}
if(@($space|Where-Object {-not $_.ok}).Count){throw 'Espace insuffisant pour les modeles selectionnes.'}
$needsNetwork=@($downloads|Where-Object {-not(Test-Path -LiteralPath $_.path)}).Count -gt 0
try {
    if($needsNetwork -and -not $HuggingFaceToken){
        $stored=Join-Path $env:USERPROFILE '.cache/huggingface/token'
        if($env:HF_TOKEN){$HuggingFaceToken=ConvertTo-SecureString $env:HF_TOKEN -AsPlainText -Force}
        elseif(Test-Path -LiteralPath $stored){$HuggingFaceToken=ConvertTo-SecureString ([IO.File]::ReadAllText($stored).Trim()) -AsPlainText -Force}
        else{$HuggingFaceToken=Read-Host 'Acces prive Hugging Face : jeton de lecture (saisie masquee, non enregistre)' -AsSecureString}
        if(-not $HuggingFaceToken.Length){throw 'Un acces Hugging Face autorise est necessaire.'}
    }
    $receipt=@()
    foreach($d in $downloads){
        $file=Receive-SuiteItem $d.item ([IO.Path]::GetDirectoryName($d.path)) $HuggingFaceToken
        $receipt+=@{model=$d.model;file=$d.path;sha256=$d.item.sha256;bytes=$d.item.bytes;status='verified'}
    }
    Write-SuiteJson @{schemaVersion=1;status='downloaded-and-verified';inference='not-tested';models=$selected.id;files=$receipt} (Join-Path $Destination 'modeles-verifies.json')
    Write-Host 'Modeles telecharges et verifies. GGUF : importer dans LLM Studio. Qushu : configurer un service Sentence Transformers. Le telechargement ne certifie pas l inference.'
} finally {$HuggingFaceToken=$null}
