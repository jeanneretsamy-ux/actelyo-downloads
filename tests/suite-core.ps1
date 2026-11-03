$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repository 'suite/ActelyoSuite.psm1') -Force
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('actelyo-suite-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$script:passed=0
function Assert($Condition,[string]$Label){if(-not $Condition){throw $Label};$script:passed++;Write-Host ('PASS '+$Label)}
function Reject([scriptblock]$Action,[string]$Label){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Assert $rejected $Label}
$file=Join-Path $fixture 'fixture.exe'
[IO.File]::WriteAllText($file,'test installer bytes, never executed')
$item=[pscustomobject]@{id='llm';name='Fixture';file='fixture.exe';version='9999.0.0';category='desktop';bytes=(Get-Item $file).Length;sha256=(Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant();url='https://github.com/jeanneretsamy-ux/actelyo-downloads/releases/download/test/fixture.exe'}
Assert ((Compare-SuiteVersion '3.0.3' '3.0.3') -eq 0) 'current version is preserved'
Assert ((Compare-SuiteVersion '3.0.4' '3.0.3') -gt 0) 'newer version is never downgraded'
Reject {Compare-SuiteVersion 'development' '3.0.3'} 'unknown version cannot be silently replaced'
Assert-SuiteItem $item
Assert ((Receive-SuiteItem $item $fixture) -eq $file) 'verified installer cache is reused without network'
[IO.File]::WriteAllText($file,'corrupt existing user file')
Reject {Receive-SuiteItem $item $fixture} 'corrupt cache is rejected before execution'
Assert (([IO.File]::ReadAllText($file)) -eq 'corrupt existing user file') 'existing file is not overwritten'
$bad=$item.PSObject.Copy();$bad.file='../escape.exe'
Reject {Assert-SuiteItem $bad} 'catalog path traversal is rejected'
$bad=$item.PSObject.Copy();$bad.url='http://github.com/insecure.exe'
Reject {Assert-SuiteItem $bad} 'insecure installer source is rejected'
$bad=$item.PSObject.Copy();$bad|Add-Member NoteProperty parts @([pscustomobject]@{url=$item.url;sha256=$item.sha256;bytes=1})
Reject {Assert-SuiteItem $bad} 'multipart total size must match installer'
$definition=[pscustomobject]@{id='fixture';registryPattern='^Fixture App';executables=@('fixture.exe')}
$registration=[pscustomobject]@{DisplayName='Fixture App';DisplayVersion='1.0.0';InstallLocation=$fixture}
Assert ((Find-SuiteInstallation $definition @($registration)).executable -eq $file) 'installed executable is found only in its own registry directory'
Reject {Find-SuiteInstallation $definition @($registration,$registration)} 'ambiguous installed application is rejected'
$space=@(Get-SuiteSpacePlan @($item) @([pscustomobject]@{reserveGiB=1}) $fixture $fixture 3)
Assert ($space.Count -eq 1 -and $space[0].requiredBytes -eq ($item.bytes+4GB)) 'download and installation reserves accumulate on the same volume'
$space=@(Get-SuiteSpacePlan @() @() $fixture $fixture 3)
Assert ($space.Count -eq 1 -and $space[0].requiredBytes -eq 3GB) 'empty remaining downloads are supported before each installer'

# Actual child PowerShell invocation: insufficient space must stop before any download or installer process.
$cliRoot=Join-Path $fixture 'cli';New-Item -ItemType Directory -Path $cliRoot | Out-Null
foreach($name in @('Installer-ActelyoSuite.ps1','ActelyoSuite.psm1','suite.json')){Copy-Item -LiteralPath (Join-Path $repository ('suite/'+$name)) -Destination $cliRoot}
$huge=$item.PSObject.Copy();$huge.bytes=100000000000000
Write-SuiteJson @{schemaVersion=1;revision='fixture';items=@($huge)} (Join-Path $cliRoot 'catalog.json')
$download=Join-Path $cliRoot 'not-created'
$childArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $cliRoot 'Installer-ActelyoSuite.ps1')+'"'),'-Mode','Install','-Apps','llm','-Accept','-Destination',('"'+$download+'"'),'-ReportDirectory',('"'+(Join-Path $cliRoot 'report')+'"'))
$child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $childArgs -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'child-out.txt') -RedirectStandardError (Join-Path $fixture 'child-error.txt') -Wait -PassThru
Assert ($child.ExitCode -ne 0) 'real installer command fails on insufficient space'
Assert (-not(Test-Path $download)) 'preflight creates no download directory and launches no installer'
$receipt=Read-SuiteJson (Join-Path $cliRoot 'report/installation.json')
Assert ($receipt.status -eq 'fail' -and $receipt.error -match 'Espace insuffisant') 'failed preflight is recorded truthfully'
Write-Host ("$script:passed meaningful core checks passed. Fixtures: $fixture")
