# Prints IPv4 addresses in the local networks that have TCP port -Port open.
# Scans the /24 of each active adapter that has a default gateway (the real home LAN),
# so VPN and virtual adapters (VirtualBox, Hyper-V) are skipped.
# A network where almost every address "answers" is a VPN/proxy adapter and is ignored.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File find-speaker.ps1 -Port 5555
param([int]$Port = 5555, [int]$TimeoutMs = 900)
$private = '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)'
$nets = @()
try {
  $nets = Get-NetIPConfiguration -ErrorAction Stop |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    ForEach-Object { $_.IPv4Address.IPAddress } |
    Where-Object { $_ -match $private } |
    ForEach-Object { ($_ -split '\.')[0..2] -join '.' }
} catch {}
if (-not $nets) {
  $nets = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -match $private } |
    ForEach-Object { ($_.IPAddressToString -split '\.')[0..2] -join '.' }
}
foreach ($n in ($nets | Sort-Object -Unique)) {
  $tasks = @()
  foreach ($i in 1..254) {
    $c = New-Object System.Net.Sockets.TcpClient
    $tasks += ,@("$n.$i", $c, $c.ConnectAsync("$n.$i", $Port))
  }
  Start-Sleep -Milliseconds $TimeoutMs
  $hits = @()
  foreach ($t in $tasks) {
    if ($t[2].Status -eq 'RanToCompletion' -and $t[1].Connected) { $hits += $t[0] }
    try { $t[1].Close() } catch {}
  }
  if ($hits.Count -le 20) { $hits }
}
