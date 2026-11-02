# Starts llama-server for chat (8080) and embeddings (8081), then runs sanity checks.
# Must run in the same Actions step as the QA driver: processes started in an
# earlier step with redirected output do not survive the end of that step.
param([string]$QwenFile, [string]$NomicFile)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force "$env:QA_OUT\logs" | Out-Null
$srv = (Get-ChildItem C:\llama -Recurse -Filter llama-server.exe | Select-Object -First 1).FullName
$chat = @('-m', "$env:CACHE\$QwenFile", '--host', '127.0.0.1', '--port', '8080', '--alias', $env:QA_LLM_MODEL,
          '-c', '8192', '-np', '1', '--jinja', '--reasoning-budget', '0', '--chat-template-kwargs', '"{\"enable_thinking\":false}"', '-t', '4')
$emb = @('-m', "$env:CACHE\$NomicFile", '--host', '127.0.0.1', '--port', '8081', '--alias', $env:QA_EMB_MODEL,
         '--embedding', '-c', '8192', '-np', '4', '-b', '2048', '-ub', '2048', '-t', '2')
$cp = Start-Process -FilePath $srv -ArgumentList $chat -RedirectStandardOutput "$env:QA_OUT\logs\llama-chat.out.log" -RedirectStandardError "$env:QA_OUT\logs\llama-chat.err.log" -WindowStyle Hidden -PassThru
Start-Sleep 8
if ($cp.HasExited) {
  Write-Host 'chat server exited (template kwargs?), retrying without --chat-template-kwargs'
  Get-Content "$env:QA_OUT\logs\llama-chat.err.log" -Tail 15
  $chat = $chat | Where-Object { $_ -notmatch 'chat-template-kwargs|enable_thinking' }
  Start-Process -FilePath $srv -ArgumentList $chat -RedirectStandardOutput "$env:QA_OUT\logs\llama-chat2.out.log" -RedirectStandardError "$env:QA_OUT\logs\llama-chat2.err.log" -WindowStyle Hidden
}
Start-Process -FilePath $srv -ArgumentList $emb -RedirectStandardOutput "$env:QA_OUT\logs\llama-emb.out.log" -RedirectStandardError "$env:QA_OUT\logs\llama-emb.err.log" -WindowStyle Hidden
foreach ($p in 8080, 8081) {
  $ok = $false
  for ($i = 0; $i -lt 90; $i++) {
    try { if ((Invoke-WebRequest "http://127.0.0.1:$p/health" -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) { $ok = $true; break } } catch {}
    Start-Sleep 2
  }
  if (-not $ok) { Get-Content "$env:QA_OUT\logs\llama-*.err.log" -Tail 40; throw "llama-server on $p not healthy" }
}
$body = @{ model = $env:QA_LLM_MODEL; messages = @(@{ role = 'user'; content = 'Réponds en un mot : quelle est la capitale de la France ?' }); max_tokens = 32 } | ConvertTo-Json -Depth 5
$r = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/v1/chat/completions -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
Write-Host "chat sanity: [$($r.choices[0].message.content)]"
$e = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8081/v1/embeddings -ContentType 'application/json' -Body (@{ model = $env:QA_EMB_MODEL; input = @('bonjour', 'bail commercial') } | ConvertTo-Json)
Write-Host "embedding sanity: $($e.data.Count) vectors of dim $($e.data[0].embedding.Count)"

