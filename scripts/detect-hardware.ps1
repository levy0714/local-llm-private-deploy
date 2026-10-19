# detect-hardware.ps1 -- detect GPU/VRAM/RAM/disk and recommend a model tier.
# ASCII-only on purpose: avoids the PowerShell 5.1 GBK / BOM parsing trap.

$ErrorActionPreference = "Continue"

Write-Host "=== Local LLM hardware check ===" -ForegroundColor Cyan

$vramGB  = 0
$gpuName = "none"

# --- NVIDIA via nvidia-smi ---
try {
    $smi = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null
    if ($smi) {
        $first  = ($smi | Select-Object -First 1)
        $parts  = $first -split ','
        $gpuName = $parts[0].Trim()
        $mb = ($parts[1] -replace '[^0-9]', '')
        if ($mb) { $vramGB = [Math]::Round([double]$mb / 1024, 1) }
    }
} catch { }

# --- fallback via WMI (unreliable for >4GB, still better than nothing) ---
if ($vramGB -eq 0) {
    try {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
              Where-Object { $_.AdapterRAM -gt 0 } |
              Sort-Object AdapterRAM -Descending | Select-Object -First 1
        if ($vc) {
            $gpuName = $vc.Name
            $vramGB  = [Math]::Round($vc.AdapterRAM / 1GB, 1)
        }
    } catch { }
}

$os    = Get-CimInstance Win32_OperatingSystem
$ramGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$cpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$disk  = Get-PSDrive -PSProvider FileSystem |
         Where-Object { $_.Free -gt 0 } |
         Sort-Object Free -Descending | Select-Object -First 1

Write-Host ""
Write-Host ("CPU       : " + $cpu)
Write-Host ("GPU       : " + $gpuName)
Write-Host ("VRAM      : " + $vramGB + " GB")
Write-Host ("RAM       : " + $ramGB + " GB")
Write-Host ("Free disk : " + $disk.Name + ":  " + [Math]::Round($disk.Free / 1GB, 1) + " GB")
Write-Host ""

$usable = 0
if ($vramGB -gt 0) {
    $usable = [Math]::Round($vramGB - 1, 1)
    if ($usable -lt 0) { $usable = 0 }
}

Write-Host "=== Recommendation ===" -ForegroundColor Cyan
if ($vramGB -gt 0) {
    Write-Host ("Usable VRAM (minus desktop overhead) approx " + $usable + " GB")
}
Write-Host ""

if ($vramGB -le 0) {
    Write-Host "No NVIDIA GPU detected -> CPU-only inference."
    Write-Host "  Use 7-8B Q4_K_M. Expect roughly 8-12 tok/s on a strong desktop CPU."
}
elseif ($vramGB -lt 6) {
    Write-Host "Tier 4-6 GB VRAM"
    Write-Host "  -> 7-8B dense, Q4_K_M (about 4.5 GB)"
}
elseif ($vramGB -lt 10) {
    Write-Host "Tier 6-8 GB VRAM"
    Write-Host "  -> 8B dense Q4_K_M (about 5.2 GB)  [fastest, simplest]"
    if ($ramGB -ge 30) {
        Write-Host "  -> OR MoE 26-30B Q4 (15-18 GB on disk):"
        Write-Host "     5-6 GB goes to VRAM, the rest to RAM."
        Write-Host "     Needs about 20 GB free RAM while running."
        Write-Host "     Roughly 2x slower than 8B, but 3-4x the parameters."
    }
}
elseif ($vramGB -lt 14) {
    Write-Host "Tier 10-12 GB VRAM"
    Write-Host "  -> 12-14B dense Q4_K_M"
}
elseif ($vramGB -lt 20) {
    Write-Host "Tier 16 GB VRAM"
    Write-Host "  -> 14B dense Q4 comfortably, or a 27-30B MoE hybrid"
}
elseif ($vramGB -lt 28) {
    Write-Host "Tier 24 GB VRAM"
    Write-Host "  -> 27-32B dense Q4_K_M"
}
else {
    Write-Host "Tier 40 GB+ VRAM"
    Write-Host "  -> 70B Q4_K_M"
}

Write-Host ""
Write-Host "Notes:"
Write-Host "  - Q4_K_M weights are about 0.63 GB per 1B parameters."
Write-Host "  - KV cache is about 0.1 MB per token for regular dense models."
Write-Host "    Sliding-window models (e.g. Gemma 4) use about 0.004 MB/token,"
Write-Host "    so long context is nearly free on those."
Write-Host "  - Always count weights + KV cache + compute buffer together."
Write-Host "    Counting weights alone is how people download models that do not fit."
Write-Host "  - Put models on a non-system drive: set OLLAMA_MODELS BEFORE the first pull."
Write-Host "  - Base preference: non-Chinese base first (different data sources,"
Write-Host "    different provider, so no single vendor sees everything)."
Write-Host "    Chinese base as fallback: stronger Chinese."
