# Starts llama-server (OpenAI-compatible API on 127.0.0.1:8080) and waits for /health.
# Run in the same workflow step as the client: the runner ends a step's background processes.
param([string] $Tag = 'run')
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:GITHUB_WORKSPACE 'qa-out'
$llamaArgs = @('-m', "`"$env:QA_MODEL_PATH`"", '--host', '127.0.0.1', '--port', '8080', '--jinja', '-c', '32768', '-np', '1',
  '-t', '4', '--alias', 'qwen3-0.6b', '--reasoning', 'off')
Write-Host "llama-server $($llamaArgs -join ' ')"
$ls = Start-Process $env:QA_LLAMA_SERVER -ArgumentList $llamaArgs -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $out "llama-server-$Tag.out.log") -RedirectStandardError (Join-Path $out "llama-server-$Tag.log")
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep 2
  if ($ls.HasExited) { break }
  try { $r = Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8080/health' -TimeoutSec 3; if ($r.StatusCode -eq 200) { Write-Host "llama-server healthy (pid $($ls.Id))"; return } } catch {}
}
Get-Content (Join-Path $out "llama-server-$Tag.log") -Tail 40
throw 'llama-server did not become healthy'
