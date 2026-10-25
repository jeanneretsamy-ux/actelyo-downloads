param([string]$Destination=(Join-Path $PSScriptRoot 'Paquets-Actelyo'),[switch]$UseBundledCatalog,[switch]$ListOnly)
$ErrorActionPreference='Stop'
function Get-ActelyoSha256([string]$File){
 $stream=[IO.File]::OpenRead($File)
 $hasher=[Security.Cryptography.SHA256]::Create()
 try { return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','') }
 finally { $hasher.Dispose(); $stream.Dispose() }
}
$catalog=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'catalog.json') -Raw | ConvertFrom-Json
if(-not $UseBundledCatalog){
 try {
  $latest=Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/jeanneretsamy-ux/actelyo-downloads/main/catalog.json' -TimeoutSec 20
  if($latest.schemaVersion -ne 1 -or -not $latest.items){throw 'Catalogue distant invalide'}
  $selected=@(foreach($selectedItem in $catalog.items){
   $matches=@($latest.items | Where-Object { $_.id -eq $selectedItem.id })
   if($matches.Count -ne 1){throw ('Version actuelle introuvable pour '+$selectedItem.id)}
   $matches[0]
  })
  $catalog.items=$selected
  Write-Host 'Catalogue actualisé : les dernières versions publiées seront proposées.'
 } catch { throw ('Impossible de vérifier les dernières versions. Réessayez avec Internet, ou utilisez -UseBundledCatalog pour choisir explicitement les versions du kit. '+$_.Exception.Message) }
}
if($ListOnly){$catalog.items | Select-Object id,name,version,file;return}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$required=($catalog.items | Measure-Object -Property bytes -Sum).Sum
$resolved=(Resolve-Path -LiteralPath $Destination).Path
$drive=Get-PSDrive -Name ([IO.Path]::GetPathRoot($resolved).Substring(0,1))
if($drive.Free -lt ($required+100MB)){throw 'Espace insuffisant. Relancez avec -Destination E:\Actelyo ou un autre disque.'}
Add-Type -AssemblyName System.Net.Http
$client=[Net.Http.HttpClient]::new()
$client.Timeout=[TimeSpan]::FromMinutes(120)
try {
 foreach($item in $catalog.items){
  if(-not $item.url -and -not $item.parts){continue}
  if($item.file -ne [IO.Path]::GetFileName($item.file) -or $item.file -match '[:\\/]' -or $item.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Entrée de catalogue invalide'}
  $target=Join-Path $Destination $item.file
  if(Test-Path -LiteralPath $target){if((Get-ActelyoSha256 $target) -ne $item.sha256){throw ('Fichier différent déjà présent : '+$target)};continue}
  $partial=$target+'.'+[guid]::NewGuid().ToString('N')+'.part'
  $output=$null
  try {
   $output=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   $parts=@($item)
   if($item.parts){$parts=@($item.parts)}
   foreach($part in $parts){
    if(([uri]$part.url).Scheme -ne 'https' -or $part.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Source ou empreinte invalide'}
    Write-Host ('Téléchargement : '+$item.name+' — '+$part.bytes+' octets')
    $inputStream=$client.GetStreamAsync([uri]$part.url).GetAwaiter().GetResult()
    $partHash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer=New-Object byte[] (1MB)
    [long]$received=0
    try {while(($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){$received+=$count;if($received -gt $part.bytes){throw 'Taille du téléchargement dépassée'};$partHash.AppendData($buffer,0,$count);$output.Write($buffer,0,$count)}
     $digest=([BitConverter]::ToString($partHash.GetHashAndReset())).Replace('-','')
     if($received -ne $part.bytes -or $digest -ne $part.sha256){throw ('Partie incorrecte : '+$item.name)}
    }finally{$inputStream.Dispose();$partHash.Dispose()}
   }
   $output.Dispose();$output=$null
   if((Get-Item -LiteralPath $partial).Length -ne $item.bytes -or (Get-ActelyoSha256 $partial) -ne $item.sha256){throw ('Empreinte incorrecte : '+$item.name)}
   Move-Item -LiteralPath $partial -Destination $target
  }finally{if($output){$output.Dispose()};if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}}
 }
}finally{$client.Dispose()}
Write-Host ('Fichiers vérifiés dans '+$resolved+'. Lancez les EXE pour installer, puis importez les GGUF dans Actelyo LLM.')
