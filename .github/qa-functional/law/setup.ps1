# Prepares the functional QA: installs Actelyo Law Harness from the catalog,
# downloads and verifies llama.cpp + Qwen3-0.6B, and starts llama-server.
param(
  [Parameter(Mandatory)] [string] $Out,
  [string] $LlamaTag = 'b6500',
  [string] $LlamaSha256 = '73e00267e852e666a6fce2c3fb7a2603dd1934a37259f3f45c2c1b6983fa605a',
  [int] $Port = 8080
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$facts = [ordered]@{}
function Save-Facts { $facts | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'setup.json') -Encoding utf8 }
function Get-Sha([string]$p) { (Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Fetch([string]$url, [string]$dest) {
  & curl.exe -fsSL --retry 5 --retry-delay 5 -o $dest $url
  if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
}

$catalog = Invoke-RestMethod 'https://raw.githubusercontent.com/jeanneretsamy-ux/actelyo-downloads/main/catalog.json'
$items = if ($catalog.items) { $catalog.items } else { $catalog }
$law = $items | Where-Object id -eq 'law-harness' | Select-Object -First 1
$qwen = $items | Where-Object id -eq 'qwen-small' | Select-Object -First 1
if (-not $law -or -not $qwen) { throw 'catalog items missing' }
$facts.lawVersion = $law.version
$facts.lawSha256 = $law.sha256

# --- llama.cpp (pinned tag; SHA-256 checked against the pin and GitHub's asset digest)
$work = Join-Path $env:RUNNER_TEMP 'qa-dl'; New-Item -ItemType Directory -Force $work | Out-Null
$hdr = @{ Authorization = "Bearer $env:GH_TOKEN"; 'X-GitHub-Api-Version' = '2022-11-28' }
$rel = Invoke-RestMethod -Headers $hdr "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LlamaTag"
$asset = $rel.assets | Where-Object name -eq "llama-$LlamaTag-bin-win-cpu-x64.zip" | Select-Object -First 1
if (-not $asset) { throw "llama.cpp $LlamaTag has no win-cpu-x64 zip: $(@($rel.assets.name) -join ', ')" }
$facts.llamaTag = $LlamaTag
$facts.llamaPublished = $rel.published_at
$facts.llamaAsset = $asset.name
$facts.llamaApiDigest = "$($asset.digest)"
$zip = Join-Path $work $asset.name
Fetch $asset.browser_download_url $zip
$zh = Get-Sha $zip
$facts.llamaSha256 = $zh
Write-Host "llama.cpp $LlamaTag published $($rel.published_at) sha256=$zh digest=$($asset.digest)"
if ((Get-Date $rel.published_at) -gt (Get-Date).AddDays(-14)) { throw 'llama.cpp tag is younger than 14 days' }
if ($LlamaSha256 -and $zh -ne $LlamaSha256.ToLowerInvariant()) { throw "llama.cpp sha256 mismatch: $zh" }
if ($asset.digest -and $asset.digest -ne "sha256:$zh") { throw "llama.cpp digest mismatch: $($asset.digest)" }
if (-not $LlamaSha256 -and -not $asset.digest) { throw 'no reference SHA-256 for llama.cpp' }
$llamaDir = Join-Path $env:RUNNER_TEMP 'llama'
Expand-Archive -LiteralPath $zip -DestinationPath $llamaDir -Force
$server = Get-ChildItem $llamaDir -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
if (-not $server) { throw 'llama-server.exe missing' }

# --- Model
$model = Join-Path $work $qwen.file
Fetch $qwen.url $model
$mh = Get-Sha $model
$facts.modelFile = $qwen.file
$facts.modelSha256 = $mh
if ($mh -ne $qwen.sha256.ToLowerInvariant()) { throw "model sha256 mismatch: $mh" }
Save-Facts

# --- Install the app (parts -> concatenate -> verify -> silent install)
$installer = Join-Path $work $law.file
$fs = [IO.File]::Create($installer)
try {
  foreach ($part in $law.parts) {
    $tmp = Join-Path $work ([IO.Path]::GetFileName($part.url))
    Fetch $part.url $tmp
    $ph = Get-Sha $tmp
    if ($ph -ne $part.sha256.ToLowerInvariant()) { throw "part sha256 mismatch: $($part.url) $ph" }
    $in = [IO.File]::OpenRead($tmp); $in.CopyTo($fs); $in.Dispose(); Remove-Item $tmp
  }
} finally { $fs.Dispose() }
$ih = Get-Sha $installer
$facts.installerSha256 = $ih
if ($ih -ne $law.sha256.ToLowerInvariant()) { throw "installer sha256 mismatch: $ih" }
$log = Join-Path $Out 'install.log'
$ip = Start-Process $installer -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=`"$log`"" -PassThru
if (-not $ip.WaitForExit(2400 * 1000)) { $ip.Kill(); throw 'installer timed out' }
$facts.installerExit = $ip.ExitCode
if ($ip.ExitCode -ne 0) { throw "installer exit $($ip.ExitCode)" }
Remove-Item $installer
$key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{4B617AF4-6EA4-4220-849A-8044F224B92C}_is1'
$entry = Get-ItemProperty $key -ErrorAction SilentlyContinue
$dir = if ($entry.InstallLocation) { $entry.InstallLocation.TrimEnd('\') } else { Join-Path $env:LOCALAPPDATA 'Programs\ActelyoLawHarness' }
$exe = Join-Path $dir 'Actelyo Law Harness.exe'
if (-not (Test-Path $exe)) { throw "app exe missing: $exe" }
$facts.installed = $dir
$facts.displayVersion = $entry.DisplayVersion
Save-Facts
"ACTELYO_INSTALLED=$dir" >> $env:GITHUB_ENV
"LLAMA_SERVER=$($server.FullName)" >> $env:GITHUB_ENV
"QA_MODEL=$model" >> $env:GITHUB_ENV
