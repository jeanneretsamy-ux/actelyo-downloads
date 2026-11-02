# Gathers logs and publishes every proof file to a DRAFT release.
$ErrorActionPreference = 'Continue'
$out = Join-Path $env:GITHUB_WORKSPACE 'qa-out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$logs = Join-Path $out 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

$copies = @{
  "$env:APPDATA\Actelyo OpenBousic\logs\server.log"   = 'app-server.log'
  "$env:APPDATA\actelyo-openbousic\config.json"       = 'app-config.json'
}
foreach ($k in $copies.Keys) { if (Test-Path $k) { Copy-Item $k (Join-Path $logs $copies[$k]) } else { "missing: $k" | Add-Content (Join-Path $logs 'missing.txt') } }
Get-ChildItem "$env:APPDATA\Actelyo OpenBousic", "$env:APPDATA\actelyo-openbousic", "$env:LOCALAPPDATA\actelyo-openbousic", 'C:\qa-projects' -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\(Cache|Code Cache|GPUCache|DawnCache|Service Worker)\\' } |
  Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize | Out-String -Width 400 | Set-Content (Join-Path $logs 'tree.txt')
Get-Process | Where-Object { $_.ProcessName -match 'actelyo|openbousic|node|llama' } | Select-Object ProcessName, Id, @{n='MB';e={[int]($_.WorkingSet64/1MB)}}, Path |
  Format-Table -AutoSize | Out-String -Width 400 | Set-Content (Join-Path $logs 'processes.txt')
& "$PSScriptRoot\desktop-shot.ps1" -Path (Join-Path $out 'shots\99-final-desktop.png')

# Stop the app and llama-server before packaging (logs get flushed).
Get-Process | Where-Object { $_.ProcessName -match 'llama-server' } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-ChildItem $out -Filter *.log | ForEach-Object { Move-Item $_.FullName $logs -Force }

# Flatten for release assets (names must be unique).
$assets = Join-Path $env:RUNNER_TEMP 'release-assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null
Get-ChildItem $out -Recurse -File | Where-Object Length -gt 0 | ForEach-Object { Copy-Item $_.FullName (Join-Path $assets $_.Name) -Force }
Compress-Archive -Path "$out\*" -DestinationPath (Join-Path $assets 'qa-out.zip') -Force

$tag = "qa-func-openbousic-$env:GITHUB_RUN_ID"
$notes = Join-Path $env:RUNNER_TEMP 'notes.md'
$summary = if (Test-Path "$out\summary.md") { Get-Content "$out\summary.md" -Raw } else { '(no summary: QA script did not finish)' }
"Functional QA of Actelyo OpenBousic. Run: $env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID`n`n$summary" | Set-Content $notes -Encoding utf8
$summary | Add-Content $env:GITHUB_STEP_SUMMARY
$files = @(Get-ChildItem $assets -File | ForEach-Object FullName)
gh release create $tag --draft --target $env:GITHUB_SHA --title "QA functional OpenBousic run $env:GITHUB_RUN_ID" --notes-file $notes @files
if ($LASTEXITCODE -ne 0) { Write-Host "release create failed: $LASTEXITCODE"; exit 1 }
Write-Host "draft release: $tag ($($files.Count) assets)"
