param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $PSScriptRoot '../suite-build' }
$OutputDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source=Join-Path $repository 'suite'
$definition=Get-Content -LiteralPath (Join-Path $source 'suite.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$catalog=Get-Content -LiteralPath (Join-Path $repository 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not(Test-Path (Join-Path $source 'qa/runtime/node_modules/playwright-core/package.json'))){throw 'Run npm ci --prefix suite/qa/runtime --ignore-scripts first.'}
$staging=Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
$kit=Join-Path $staging ('Actelyo-Suite-'+$definition.version)
New-Item -ItemType Directory -Path $kit -Force | Out-Null
foreach($name in @('Installer.cmd','Verifier.cmd','Installer-ActelyoSuite.ps1','ActelyoSuite.psm1','suite.json','LIRE-MOI.md','qa')){
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $kit -Recurse
}
foreach($name in @('Installer.cmd','Verifier.cmd')){
    $file=Join-Path $kit $name
    [IO.File]::WriteAllText($file,([IO.File]::ReadAllText($file) -replace '\r?\n',"`r`n"),[Text.Encoding]::ASCII)
}
Copy-Item -LiteralPath (Join-Path $repository 'catalog.json') -Destination (Join-Path $kit 'catalog.json')
$hashes=@(Get-ChildItem -LiteralPath $kit -Recurse -File | ForEach-Object {
    $relative=$_.FullName.Substring($kit.Length+1).Replace('\','/')
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$relative
})
[IO.File]::WriteAllLines((Join-Path $kit 'SHA256SUMS.txt'),$hashes,(New-Object Text.UTF8Encoding($false)))
$archive=Join-Path $OutputDirectory ('Actelyo-Suite-'+$definition.version+'-Kit.zip')
if(Test-Path -LiteralPath $archive){throw 'Output already exists; use a fresh output directory.'}
Compress-Archive -Path (Join-Path $kit '*') -DestinationPath $archive
$receipt=@{kitVersion=$definition.version;catalogRevision=$catalog.revision;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $archive).Length;sourceCommit=(& git -C $repository rev-parse HEAD);sourceDirty=(@(& git -C $repository status --porcelain).Count -gt 0);applications=@($catalog.items|Where-Object{$_.id -in $definition.applications.id}|Select-Object id,version,sha256);certification='not-certified-by-build; see clean-machine QA report'}
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'kit-manifest.json') -Encoding UTF8
Write-Host $archive
