# Reads the public catalog, downloads + verifies the LLM Studio installer and the Qwen3-0.6B model,
# installs the app silently and exports APP_EXE / MODEL_FILE for the next steps.
$ErrorActionPreference = 'Stop'
$out = $env:QA_OUT
New-Item -ItemType Directory -Force -Path $out | Out-Null
$checks = [ordered]@{}
$facts = [ordered]@{}
function Check($name, [bool]$ok, $detail = '') {
  $checks[$name] = [ordered]@{ ok = $ok; detail = "$detail" }
  Write-Host "[$(if ($ok) {'PASS'} else {'FAIL'})] $name $detail"
}
function Save { [ordered]@{ facts = $facts; checks = $checks } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'prepare.json') -Encoding utf8 }

$catalog = Invoke-RestMethod 'https://raw.githubusercontent.com/jeanneretsamy-ux/actelyo-downloads/main/catalog.json'
$llm = $catalog.items | Where-Object id -eq 'llm' | Select-Object -First 1
$qwen = $catalog.items | Where-Object id -eq 'qwen-small' | Select-Object -First 1
$facts.catalogRevision = $catalog.revision
$facts.llm = $llm
$facts.model = $qwen

# Installer
$installer = Join-Path $env:RUNNER_TEMP $llm.file
& curl.exe -sSfL --retry 3 -o $installer $llm.url
$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
Check 'installer sha256 matches catalog' ($hash -eq $llm.sha256.ToLower()) $hash
if ($hash -ne $llm.sha256.ToLower()) { Save; exit 1 }

# Model (downloaded in parallel with the install)
$modelDir = Join-Path $env:RUNNER_TEMP 'qa-model'
New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
$model = Join-Path $modelDir $qwen.file
$dl = Start-Process curl.exe -ArgumentList '-sSfL','--retry','3','-o',"`"$model`"",$qwen.url -PassThru -NoNewWindow

$log = Join-Path $out 'install.log'
$p = Start-Process $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/LOG=`"$log`"" -PassThru
$p.WaitForExit()
Check 'silent install exit code 0' ($p.ExitCode -eq 0) "exit=$($p.ExitCode)"
$entry = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -like 'Actelyo LLM Desktop*' } | Select-Object -First 1
Check 'Apps & features entry "Actelyo LLM Desktop*"' ($null -ne $entry) "$($entry.DisplayName) $($entry.DisplayVersion)"
$installDir = if ($entry.InstallLocation) { $entry.InstallLocation } else { Join-Path $env:LOCALAPPDATA 'Programs\Actelyo LLM Desktop' }
$exe = Join-Path $installDir 'Actelyo LLM.exe'
Check 'Actelyo LLM.exe present' (Test-Path $exe) $exe
$facts.installLocation = $installDir; $facts.displayName = $entry.DisplayName
$facts.displayVersion = $entry.DisplayVersion
$facts.exeProductVersion = (Get-Item $exe).VersionInfo.ProductVersion
$facts.bundledRuntimes = @(Get-ChildItem $installDir -Recurse -Filter llama-server.exe -ErrorAction SilentlyContinue | ForEach-Object FullName)

$dl.WaitForExit()
$mhash = (Get-FileHash $model -Algorithm SHA256).Hash.ToLower()
Check 'model sha256 matches catalog (qwen-small)' ($mhash -eq $qwen.sha256.ToLower()) $mhash
$facts.modelBytes = (Get-Item $model).Length
Save
"APP_EXE=$exe" | Add-Content $env:GITHUB_ENV
"MODEL_FILE=$model" | Add-Content $env:GITHUB_ENV
"MODEL_SHA256=$($qwen.sha256)" | Add-Content $env:GITHUB_ENV
if ($checks.Values | Where-Object { -not $_.ok }) { exit 1 }
