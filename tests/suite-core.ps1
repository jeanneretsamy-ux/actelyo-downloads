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
Assert ((Compare-SuiteVersion '1.8.6-rc.4' '1.8.6-rc.4') -eq 0) 'installed release candidate is recognized after NSIS installation'
Assert ((Compare-SuiteVersion '1.8.6' '1.8.6-rc.4') -gt 0) 'stable installation is never downgraded to its candidate'
Assert ((Compare-SuiteVersion '1.8.6-rc.10' '1.8.6-rc.4') -gt 0) 'candidate numeric identifiers compare numerically'
Assert ((Compare-SuiteVersion '1.8.6-rc.4' '1.8.5') -gt 0) 'newer core candidate follows the previous stable version'
Assert ((Compare-SuiteVersion '1.8.6-rc.4' '1.8.6-RC.4') -gt 0) 'prerelease labels retain case-sensitive semantic ordering'
Reject {Compare-SuiteVersion '1.8.6-rc.04' '1.8.6-rc.4'} 'ambiguous candidate identifiers are refused'
Reject {Compare-SuiteVersion 'development' '3.0.3'} 'unknown version cannot be silently replaced'
Assert-SuiteItem $item
Assert ((@(Get-SuiteInstallerArguments $item 'C:\QA logs\install.log') -join ' ') -match '/VERYSILENT.* /LOG="C:\\QA logs\\install.log"') 'legacy Inno installers retain their silent mode and quoted log path'
$nsis=$item.PSObject.Copy();$nsis|Add-Member NoteProperty installer 'nsis'
Assert ((@(Get-SuiteInstallerArguments $nsis 'unused') -join ' ') -ceq '/S') 'NSIS receives its case-sensitive silent switch without Inno options'
$unknown=$item.PSObject.Copy();$unknown|Add-Member NoteProperty installer 'unknown'
Reject {Get-SuiteInstallerArguments $unknown 'unused'} 'unknown installer formats are rejected before execution'
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
$nsisDefinition=$definition.PSObject.Copy();$nsisDefinition|Add-Member NoteProperty registryIconFallback $true
$nsisRegistration=[pscustomobject]@{DisplayName='Fixture App';DisplayVersion='1.0.0';DisplayIcon=('"'+$file+'",0')}
Assert ((Find-SuiteInstallation $nsisDefinition @($nsisRegistration)).executable -eq $file) 'NSIS registration without InstallLocation resolves its exact existing executable icon'
$badRegistration=$nsisRegistration.PSObject.Copy();$badRegistration.DisplayIcon=Join-Path $fixture 'another.exe'
Reject {Find-SuiteInstallation $nsisDefinition @($badRegistration)} 'NSIS cannot resolve an unrelated or missing executable'
Reject {Find-SuiteInstallation $definition @($nsisRegistration)} 'registry icon fallback must be explicitly enabled for the product'
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
Assert ($child.ExitCode -eq 1) 'real installer command fails with exit 1 on insufficient space'
Assert (-not(Test-Path $download)) 'preflight creates no download directory and launches no installer'
$receipt=Read-SuiteJson (Join-Path $cliRoot 'report/installation.json')
Assert ($receipt.status -eq 'fail' -and $receipt.error -match 'Espace insuffisant') 'failed preflight is recorded truthfully'
$cache=Join-Path $cliRoot 'cache';New-Item -ItemType Directory -Path $cache | Out-Null
[IO.File]::WriteAllText((Join-Path $cache $item.file),'test installer bytes, never executed')
Write-SuiteJson @{schemaVersion=1;revision='fixture';items=@($item)} (Join-Path $cliRoot 'catalog.json')
$downloadArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $cliRoot 'Installer-ActelyoSuite.ps1')+'"'),'-Mode','Download','-Apps','llm','-Destination',('"'+$cache+'"'),'-ReportDirectory',('"'+(Join-Path $cliRoot 'offline-report')+'"'))
$offline=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $downloadArgs -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'offline-out.txt') -RedirectStandardError (Join-Path $fixture 'offline-error.txt') -Wait -PassThru
Assert ($offline.ExitCode -eq 0) 'real offline download command reuses verified cache without fetching or installing'
$offlineReceipt=Read-SuiteJson (Join-Path $cliRoot 'offline-report/installation.json')
Assert ($offlineReceipt.status -eq 'downloaded' -and $offlineReceipt.interoperability -eq 'not-tested') 'download completion is never presented as interoperability success'
Write-Host ("$script:passed meaningful core checks passed. Fixtures: $fixture")
