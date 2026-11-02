# Prepares the Windows runner for the functional QA of Actelyo OpenBousic:
# downloads and verifies the installer, the model and llama-server, installs the
# app silently and starts llama-server (OpenAI-compatible API on 127.0.0.1:8080).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$LlamaTag = 'b11600'   # published 2026-10-13
$LlamaZipSha256 = 'ea688fd5cd702f0f1a3703d1b5ba098a9aea21a87221c8d7b2c50245e3beabdf'

$out = Join-Path $env:GITHUB_WORKSPACE 'qa-out'
$work = Join-Path $env:RUNNER_TEMP 'qa-work'
New-Item -ItemType Directory -Force -Path $out, $work | Out-Null
$facts = [ordered]@{}

function Fetch($url, $dest) {
  & curl.exe -sSL --fail --retry 4 --retry-delay 5 -o $dest $url
  if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE): $url" }
}
function Verify($file, $expected, $label) {
  $h = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
  Write-Host "$label sha256=$h expected=$($expected.ToLower())"
  if ($h -ne $expected.ToLower()) { throw "$label SHA-256 mismatch: $h != $expected" }
  return $h
}

# Catalog
$catalogFile = Join-Path $work 'catalog.json'
Fetch 'https://raw.githubusercontent.com/jeanneretsamy-ux/actelyo-downloads/main/catalog.json' $catalogFile
$catalog = Get-Content $catalogFile -Raw | ConvertFrom-Json
$items = if ($catalog.items) { $catalog.items } else { $catalog }
$app = $items | Where-Object id -eq 'openbousic' | Select-Object -First 1
$model = $items | Where-Object id -eq 'qwen-small' | Select-Object -First 1
if (-not $app -or -not $model) { throw 'catalog items openbousic / qwen-small not found' }
$facts.appVersion = $app.version; $facts.appUrl = $app.url
$facts.modelFile = $model.file; $facts.modelUrl = $model.url

# Installer
$installer = Join-Path $work 'openbousic-setup.exe'
Fetch $app.url $installer
$facts.installerSha256 = Verify $installer $app.sha256 'installer'

# Model (in parallel with llama.cpp download)
$modelPath = Join-Path $work $model.file
$modelJob = Start-Job -ScriptBlock { param($u, $d) & curl.exe -sSL --fail --retry 4 --retry-delay 5 -o $d $u; $LASTEXITCODE } -ArgumentList $model.url, $modelPath

# llama.cpp
$llamaZip = Join-Path $work "llama-$LlamaTag-bin-win-cpu-x64.zip"
Fetch "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaTag/llama-$LlamaTag-bin-win-cpu-x64.zip" $llamaZip
$facts.llamaTag = $LlamaTag
$facts.llamaZipSha256 = Verify $llamaZip $LlamaZipSha256 'llama.cpp zip'
try {
  $rel = gh api "repos/ggml-org/llama.cpp/releases/tags/$LlamaTag" | ConvertFrom-Json
  $facts.llamaPublishedAt = $rel.published_at
  $asset = $rel.assets | Where-Object name -eq "llama-$LlamaTag-bin-win-cpu-x64.zip"
  $facts.llamaApiDigest = $asset.digest
} catch { Write-Host "release metadata lookup failed: $_" }
$llamaDir = Join-Path $work 'llama'
Expand-Archive $llamaZip -DestinationPath $llamaDir -Force
$server = Get-ChildItem $llamaDir -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
if (-not $server) { throw 'llama-server.exe not found in the zip' }

# Silent install
$log = Join-Path $out 'install.log'
$p = Start-Process $installer -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=`"$log`"" -PassThru
if (-not $p.WaitForExit(1200 * 1000)) { throw 'installer timed out' }
$facts.installerExitCode = $p.ExitCode
if ($p.ExitCode -ne 0) { throw "installer exit code $($p.ExitCode)" }
$roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
$entry = Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Actelyo OpenBousic*' } | Select-Object -First 1
if (-not $entry) { throw 'uninstall entry not found' }
$facts.displayName = $entry.DisplayName; $facts.displayVersion = $entry.DisplayVersion; $facts.installLocation = $entry.InstallLocation
$appExe = $null
if ($entry.DisplayIcon) { $c = ($entry.DisplayIcon -split ',')[0].Trim('"'); if ((Test-Path $c) -and $c -like '*.exe' -and $c -notlike '*unins*') { $appExe = $c } }
if (-not $appExe) { $appExe = (Get-ChildItem $entry.InstallLocation -Filter *.exe | Where-Object Name -notlike 'unins*' | Sort-Object Length -Descending | Select-Object -First 1).FullName }
$facts.appExe = $appExe
Write-Host "app exe: $appExe"

# Model checksum
$rc = Receive-Job $modelJob -Wait
if ($rc -ne 0) { throw "model download failed ($rc)" }
$facts.modelSha256 = Verify $modelPath $model.sha256 'model'

# llama-server
& $server.FullName --version *> (Join-Path $out 'llama-server-version.txt')
& $server.FullName --help *> (Join-Path $out 'llama-server-help.txt')
$llamaArgs = @('-m', "`"$modelPath`"", '--host', '127.0.0.1', '--port', '8080', '--jinja', '-c', '32768', '-np', '1',
  '-t', '4', '--alias', 'qwen3-0.6b', '--chat-template-kwargs', '"{\"enable_thinking\":false}"')
$facts.llamaArgs = ($llamaArgs -join ' ')
$ls = Start-Process $server.FullName -ArgumentList $llamaArgs -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $out 'llama-server.out.log') -RedirectStandardError (Join-Path $out 'llama-server.log')
$ok = $false
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep 2
  if ($ls.HasExited) { break }
  try { $r = Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8080/health' -TimeoutSec 3; if ($r.StatusCode -eq 200) { $ok = $true; break } } catch {}
}
if (-not $ok) { Get-Content (Join-Path $out 'llama-server.log') -Tail 40; throw 'llama-server did not become healthy' }

# Baseline: the model answers directly over the OpenAI-compatible API
$body = @{ model = 'qwen3-0.6b'; max_tokens = 64; messages = @(@{ role = 'user'; content = 'Say hello in one short sentence.' }) } | ConvertTo-Json -Depth 5
$sw = [Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8080/v1/chat/completions' -ContentType 'application/json' -Body $body -TimeoutSec 300
$facts.baselineReply = $resp.choices[0].message.content
$facts.baselineSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Write-Host "baseline reply ($($facts.baselineSeconds)s): $($facts.baselineReply)"
(Invoke-RestMethod 'http://127.0.0.1:8080/v1/models') | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'llama-models.json')

# Diagnostic: the same request the app server makes, with the app's bundled Node.js
$bundledNode = Join-Path $entry.InstallLocation 'resources\node\node.exe'
$diag = Join-Path $work 'diag-fetch.mjs'
@'
for (const u of ['http://127.0.0.1:8080/v1/models', 'http://localhost:8080/v1/models']) {
  for (const h of [{ 'Content-Type': 'application/json' }, {}]) {
    try {
      const r = await fetch(u, { method: 'GET', headers: h, signal: AbortSignal.timeout(10000) })
      const t = await r.text()
      console.log(u, JSON.stringify(h), r.status, t.slice(0, 200))
    } catch (e) { console.log(u, JSON.stringify(h), 'ERR', e.message, e.cause?.message ?? '') }
  }
}
console.log('node', process.version)
'@ | Set-Content $diag -Encoding utf8
& $bundledNode $diag *> (Join-Path $out 'diag-fetch.txt')
Get-Content (Join-Path $out 'diag-fetch.txt')

New-Item -ItemType Directory -Force -Path 'C:\qa-projects' | Out-Null
$facts | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'setup-facts.json') -Encoding utf8
"APP_EXE=$appExe" | Add-Content $env:GITHUB_ENV
"QA_OUT=$out" | Add-Content $env:GITHUB_ENV
