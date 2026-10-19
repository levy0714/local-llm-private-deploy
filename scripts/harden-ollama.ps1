# harden-ollama.ps1 -- cut Ollama's outbound network access.
# Self-elevates (UAC prompt). ASCII-only on purpose.
#
# What it does:
#   1. sets OLLAMA_NO_CLOUD=1 (user scope)
#   2. adds hosts entries pointing ollama.com / registry.ollama.ai / ollama.ai to 127.0.0.1
#   3. creates outbound block firewall rules for ollama.exe and "ollama app.exe"
#   4. prints verification
#
# Why this is safe for local inference:
#   Windows Firewall does NOT filter loopback traffic, so 127.0.0.1:11434 keeps working.

$ErrorActionPreference = "Continue"

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting administrator rights - click YES on the UAC prompt..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
    )
    return
}

$log = Join-Path $env:TEMP "harden-ollama.log"
"=== harden-ollama $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File $log -Encoding UTF8

# ---------- 1) NO_CLOUD ----------
[Environment]::SetEnvironmentVariable("OLLAMA_NO_CLOUD", "1", "User")
$chk = [Environment]::GetEnvironmentVariable("OLLAMA_NO_CLOUD", "User")
"OLLAMA_NO_CLOUD = $chk (User scope)" | Out-File $log -Append -Encoding UTF8

# ---------- 2) hosts ----------
$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$backup    = Join-Path $env:TEMP ("hosts.backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $hostsPath $backup -Force
"hosts backup -> $backup" | Out-File $log -Append -Encoding UTF8

$current = [IO.File]::ReadAllText($hostsPath)
if ($current -match 'ollama\.com') {
    "hosts: ollama entries already present, skipped" | Out-File $log -Append -Encoding UTF8
} else {
    $add = "`r`n# Ollama outbound block (local-llm-private-deploy)`r`n" +
           "127.0.0.1 ollama.com`r`n" +
           "127.0.0.1 registry.ollama.ai`r`n" +
           "127.0.0.1 ollama.ai`r`n"
    try {
        $fs = [IO.File]::Open($hostsPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $sw = New-Object IO.StreamWriter($fs)
        $sw.Write($add)
        $sw.Close()
        $fs.Close()
        "hosts: entries added" | Out-File $log -Append -Encoding UTF8
    } catch {
        "hosts: FAILED -> $_" | Out-File $log -Append -Encoding UTF8
    }
}

# ---------- 3) firewall ----------
$exes = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe")
)
foreach ($exe in $exes) {
    if (-not (Test-Path $exe)) {
        "firewall: missing $exe (skipped)" | Out-File $log -Append -Encoding UTF8
        continue
    }
    $ruleName = "Block Ollama outbound - " + (Split-Path $exe -Leaf)
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    try {
        New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Program $exe `
            -Action Block -Profile Any -Enabled True | Out-Null
        "firewall: rule created -> $ruleName" | Out-File $log -Append -Encoding UTF8
    } catch {
        "firewall: FAILED for $exe -> $_" | Out-File $log -Append -Encoding UTF8
    }
}

# ---------- 4) verify ----------
Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan

Write-Host "--- hosts (last 5 lines) ---"
Get-Content $hostsPath -Tail 5

Write-Host ""
Write-Host "--- firewall rules ---"
$rules = Get-NetFirewallRule -DisplayName "Block Ollama*" -ErrorAction SilentlyContinue
if ($rules) {
    $rules | Select-Object DisplayName, Enabled, Direction, Action | Format-Table -AutoSize
} else {
    Write-Host "  none found"
}

Write-Host "--- ollama.com resolves to ---"
try {
    $ips = (Resolve-DnsName ollama.com -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress
    if ($ips) { $ips | ForEach-Object { Write-Host ("  " + $_) } } else { Write-Host "  (no A record)" }
} catch {
    Write-Host "  (resolution failed - that is also fine)"
}

Write-Host ""
Write-Host "Log: $log"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Restart Ollama so OLLAMA_NO_CLOUD takes effect."
Write-Host "     Before killing it, run:  ollama stop <model>"
Write-Host "     (killing ollama.exe directly can orphan llama-server.exe and leak gigabytes of RAM)"
Write-Host "  2. Run verify-local-only.ps1 to confirm local inference still works."
Write-Host "  3. Automatic update checks will now fail. That is expected."
Write-Host "     To upgrade later, download the installer manually."
