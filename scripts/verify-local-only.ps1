# verify-local-only.ps1 -- prove that inference is local and nothing leaks out.
# ASCII-only on purpose.
#
# Usage:
#   .\verify-local-only.ps1                 # checks service + network only
#   .\verify-local-only.ps1 -Model qwen3:8b # also runs a real inference and times it

param(
    [string]$Model = "",
    [int]$NumPredict = 60
)

$ErrorActionPreference = "Continue"
$pass = 0
$fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) {
        Write-Host ("  [PASS] " + $Name + $(if ($Detail) { "  -- " + $Detail } else { "" })) -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host ("  [FAIL] " + $Name + $(if ($Detail) { "  -- " + $Detail } else { "" })) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "=== Local-only verification ===" -ForegroundColor Cyan
Write-Host ""

# ---------- 1) service reachable ----------
$ver = $null
try { $ver = (curl.exe -s --max-time 10 "http://127.0.0.1:11434/api/version" | Out-String) } catch { }
Check "Ollama service responds on 127.0.0.1:11434" ($ver -and $ver -match 'version') ($ver.Trim())

# ---------- 2) listening scope ----------
$ollamaPids = @((Get-Process -Name ollama -ErrorAction SilentlyContinue).Id)
$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
             Where-Object { $_.OwningProcess -in $ollamaPids }
$bad = $listeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }
Check "Service listens on loopback only (not 0.0.0.0)" (-not $bad) `
      (($listeners | ForEach-Object { $_.LocalAddress + ":" + $_.LocalPort }) -join ", ")

# ---------- 3) hosts block ----------
$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$hostsTxt  = ""
try { $hostsTxt = [IO.File]::ReadAllText($hostsPath) } catch { }
Check "hosts blocks ollama.com" ($hostsTxt -match '127\.0\.0\.1\s+ollama\.com')

# ---------- 4) DNS actually redirected ----------
$resolved = ""
try {
    $resolved = ((Resolve-DnsName ollama.com -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress) -join ","
} catch { }
Check "ollama.com resolves to 127.0.0.1" ($resolved -match '127\.0\.0\.1') $resolved

# ---------- 5) firewall rules ----------
$rules = Get-NetFirewallRule -DisplayName "Block Ollama*" -ErrorAction SilentlyContinue
Check "Outbound firewall rules exist" ($rules -and $rules.Count -ge 1) (($rules | ForEach-Object { $_.DisplayName }) -join "; ")

# ---------- 6) no credentials ----------
$ollamaHome = Join-Path $env:USERPROFILE ".ollama"
$authFile   = Join-Path $ollamaHome "auth.json"
$hasToken   = Test-Path $authFile
Check "No account credential file in ~\.ollama" (-not $hasToken) `
      $(if ($hasToken) { "auth.json EXISTS - you are signed in" } else { "only local signing keys expected" })

# ---------- 7) no external connections ----------
$allPids = @((Get-Process -Name ollama -ErrorAction SilentlyContinue).Id) +
           @((Get-Process -Name llama-server -ErrorAction SilentlyContinue).Id)
$ext = Get-NetTCPConnection -ErrorAction SilentlyContinue |
       Where-Object { $_.OwningProcess -in $allPids -and $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$)' }
Check "No external connections from ollama / llama-server" (-not $ext) `
      (($ext | ForEach-Object { $_.RemoteAddress + ":" + $_.RemotePort }) -join ", ")

# ---------- 8) real inference ----------
if ($Model) {
    Write-Host ""
    Write-Host ("  Running a real inference on '$Model' ...")
    $body = @{
        model   = $Model
        prompt  = "Reply with exactly one word: ok"
        stream  = $false
        options = @{ num_predict = $NumPredict }
    } | ConvertTo-Json -Depth 5 -Compress
    $reqPath = Join-Path $env:TEMP "_verify_req.json"
    $resPath = Join-Path $env:TEMP "_verify_res.json"
    [IO.File]::WriteAllText($reqPath, $body, (New-Object System.Text.UTF8Encoding($false)))

    $t0 = Get-Date
    curl.exe -s --max-time 600 "http://127.0.0.1:11434/api/generate" `
        -H "Content-Type: application/json" --data-binary "@$reqPath" -o "$resPath"
    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

    $speed = 0
    try {
        $r = [IO.File]::ReadAllText($resPath) | ConvertFrom-Json
        if ($r.eval_duration -gt 0) { $speed = [Math]::Round($r.eval_count / ($r.eval_duration / 1e9), 1) }
        Check "Local inference produced output" ([string]$r.response -ne "") `
              ("$($r.eval_count) tok in $secs s  =>  $speed tok/s")
    } catch {
        Check "Local inference produced output" $false "unparseable response"
    }
}

Write-Host ""
Write-Host ("=== " + $pass + " passed, " + $fail + " failed ===") -ForegroundColor Cyan
if ($fail -eq 0) {
    Write-Host "All good: inference is local, nothing is leaving the machine." -ForegroundColor Green
} else {
    Write-Host "Some checks failed - review them above before trusting this setup." -ForegroundColor Yellow
}
