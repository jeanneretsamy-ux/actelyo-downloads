# Publishes every proof in QA_OUT to a DRAFT release qa-func-llm-<run_id> (never published).
$out = $env:QA_OUT
New-Item -ItemType Directory -Force -Path $out | Out-Null
$tag = "qa-func-llm-$env:GITHUB_RUN_ID"
$notes = Join-Path $out 'release-notes.md'
$summary = if (Test-Path (Join-Path $out 'summary.md')) { Get-Content (Join-Path $out 'summary.md') -Raw } else { 'QA did not produce a summary.' }
"Run: $env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID`n`n$summary" | Set-Content $notes -Encoding utf8
# Zip the user-data logs of the app if present
$files = @(Get-ChildItem $out -File | Where-Object { $_.Extension -in '.png', '.json', '.log', '.txt', '.md' } | ForEach-Object FullName)
Write-Host "uploading $($files.Count) files"
gh release create $tag --repo $env:GITHUB_REPOSITORY --draft --target $env:GITHUB_SHA --title "QA functional LLM Studio $env:GITHUB_RUN_ID" --notes-file $notes @files
if ($LASTEXITCODE -ne 0) { Write-Host 'release create failed'; exit 1 }
Write-Host "draft release $tag created"
