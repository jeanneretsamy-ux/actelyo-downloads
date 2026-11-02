# Starts llama-server for the QA (must run in the same step as the UI driver:
# the runner terminates processes left behind when a step ends).
param(
  [Parameter(Mandatory)] [string] $Out,
  [int] $Port = 8080
)
$ErrorActionPreference = 'Stop'
$facts = [ordered]@{}
function Save-Facts { $facts | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'llama.json') -Encoding utf8 }
$server = Get-Item $env:LLAMA_SERVER
$model = $env:QA_MODEL
# --- Start llama-server (64K context: Hermes refuses windows below 64,000 tokens)
$help = (& $server.FullName --help 2>&1 | Out-String)
$llamaArgs = @('-m', $model, '--host', '127.0.0.1', '--port', "$Port", '-c', '65536', '-np', '1', '--jinja',
  '--alias', 'qwen3-0.6b', '-t', "$([Environment]::ProcessorCount)", '--no-webui')
if ($help -notmatch '--no-webui') { $llamaArgs = $llamaArgs | Where-Object { $_ -ne '--no-webui' } }
if ($help -match '--reasoning-budget') { $llamaArgs += @('--reasoning-budget', '0') }
if ($help -match 'flash-attn[^\r\n]*(on\|off|\[on)') { $llamaArgs += @('-fa', 'on', '-ctk', 'q8_0', '-ctv', 'q8_0') }
$facts.llamaArgs = ($llamaArgs -join ' ')
Write-Host "llama-server $($facts.llamaArgs)"
$p = Start-Process $server.FullName -ArgumentList $llamaArgs -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $Out 'llama-server.out.log') -RedirectStandardError (Join-Path $Out 'llama-server.log')
$facts.llamaPid = $p.Id
$ready = $false
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep 2
  if ($p.HasExited) { throw "llama-server exited: $($p.ExitCode)" }
  try { $h = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3; if ($h.status -eq 'ok') { $ready = $true; break } } catch {}
}
if (-not $ready) { throw 'llama-server not healthy' }
$facts.models = (Invoke-RestMethod "http://127.0.0.1:$Port/v1/models").data | ForEach-Object id
$props = Invoke-RestMethod "http://127.0.0.1:$Port/props"
$facts.serverNctx = $props.default_generation_settings.n_ctx
$body = @{ model = 'qwen3-0.6b'; max_tokens = 64; temperature = 0
  messages = @(@{ role = 'user'; content = 'In one short sentence, what is a contract?' }) } | ConvertTo-Json -Depth 5
$t0 = Get-Date
$r = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
$facts.directReply = $r.choices[0].message.content
$facts.directReplySeconds = [int]((Get-Date) - $t0).TotalSeconds
Write-Host "direct reply: $($facts.directReply)"
Save-Facts
if (-not "$($facts.directReply)".Trim()) { throw 'llama-server returned an empty reply' }

