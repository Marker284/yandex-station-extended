<#
.SYNOPSIS
  Автономный установщик пульта для Яндекс Станции 1.
.DESCRIPTION
  Внутри этого файла уже находятся сервер Android и интерфейс. Репозиторий,
  Python, Java, ADB и Entware на ПК не нужны. Отсутствующие ТВ-приложения
  скачиваются из официальных GitHub-релизов. Нужны root и SSH через AliceBridge.
  Пароль пульта пользователь придумывает в браузере при первом запуске.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Ip <STATION_IP> -RemoteOnly
#>
[CmdletBinding()]
param(
    [string]$Ip,
    [ValidateRange(1,65535)][int]$Port = 22,
    [string]$Key,
    [string]$BindAddress,
    [switch]$RemoteOnly,
    [switch]$UpdateApps,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Quote-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-StationSsh([string]$Command, [byte[]]$Payload) {
    $nativeArgs = @($script:sshOptions) + @("root@$Ip", $Command)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:sshPath
    $info.Arguments = (($nativeArgs | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $false
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    # Windows PowerShell 5.1 may prepend a UTF-8 BOM to redirected stdin.
    # The payload must stay byte-for-byte identical to the embedded tar archive.
    $previousInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        [void]$proc.Start()
        $reading = $proc.StandardOutput.ReadToEndAsync()
        $proc.StandardInput.BaseStream.Write($Payload, 0, $Payload.Length)
        $proc.StandardInput.Close()
        $output = $reading.GetAwaiter().GetResult()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "SSH завершился с ошибкой $($proc.ExitCode). $output" }
        return $output
    } finally { $proc.Dispose(); [Console]::InputEncoding = $previousInputEncoding }
}
function Same-Subnet([string]$A, [string]$B, [int]$Prefix) {
    $left = [Net.IPAddress]::Parse($A).GetAddressBytes()
    $right = [Net.IPAddress]::Parse($B).GetAddressBytes()
    for ($bit = 0; $bit -lt $Prefix; $bit++) {
        $octet = [int][math]::Floor($bit / 8)
        $mask = 1 -shl (7 - ($bit % 8))
        if (($left[$octet] -band $mask) -ne ($right[$octet] -band $mask)) { return $false }
    }
    return $true
}

$work = $null
try {
    Write-Host "`nПульт для Станции 1`n" -ForegroundColor Green
    if (-not $Ip) { $Ip = (Read-Host 'IP-адрес Станции').Trim() }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Нужен корректный IPv4-адрес колонки.' }
    $script:sshPath = (Get-Command ssh.exe -ErrorAction Stop).Source
    $tarPath = (Get-Command tar.exe -ErrorAction Stop).Source
    if (-not $Key) {
        foreach ($name in @('alice_ed25519', 'id_ed25519', 'id_rsa')) {
            $candidate = Join-Path $env:USERPROFILE ".ssh\$name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $Key = $candidate; break }
        }
    }
    if ($Key) { $Key = (Resolve-Path -LiteralPath $Key).Path }
    if (-not $BindAddress -and (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) {
        foreach ($adapter in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
            if ($adapter.IPAddress -notmatch '^(127\.|169\.254\.)' -and (Same-Subnet $adapter.IPAddress $Ip $adapter.PrefixLength)) { $BindAddress = $adapter.IPAddress; break }
        }
    }
    $script:sshOptions = @('-p', "$Port", '-o', 'ConnectTimeout=12', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ServerAliveInterval=15')
    if ($Key) { $script:sshOptions += @('-i', $Key, '-o', 'IdentitiesOnly=yes') }
    if ($BindAddress) { $script:sshOptions += @('-o', "BindAddress=$BindAddress") }

    Write-Host '[1/4] Проверяю подключение и модель Станции...'
    if (-not $Key) { Write-Host 'Введите пароль root, когда его запросит SSH. Он не сохраняется.' }
    $preflightScript = @'
export ANDROID_DATA=/data ANDROID_ROOT=/system
echo ROOT=$(id -u)
echo SDK=$(getprop ro.build.version.sdk)
echo PLATFORM=$(getprop ro.board.platform)
echo ABI=$(getprop ro.product.cpu.abi)
for pkg in com.conreo.couchytv org.smarttube.stable com.v2ray.ang; do
    installed=$(pm path $pkg 2>/dev/null)
    case "$installed" in package:*) echo APP=$pkg;; esac
done
test -f /data/dropbear/start.sh && echo ALICEBRIDGE=yes
true
'@
    $preflight = Invoke-StationSsh 'sh' ([Text.Encoding]::UTF8.GetBytes($preflightScript.Replace("`r`n", "`n") + "`n"))
    if ($preflight -notmatch '(?m)^ROOT=0\s*$') { throw 'Нужен SSH-доступ от root.' }
    if ($preflight -notmatch '(?m)^SDK=23\s*$' -or $preflight -notmatch '(?m)^PLATFORM=tulip\s*$') { throw 'Установщик предназначен для Яндекс Станции 1: tulip, Android 6.0.1.' }
    if ($preflight -notmatch 'ALICEBRIDGE=yes') { throw 'Сначала установите root и SSH через AliceBridge: https://hackalice.me/start/alicebridge/' }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('station-remote-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $packed = [Convert]::FromBase64String('__PAYLOAD_BASE64__')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash($packed)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($digest -ne '__PAYLOAD_SHA256__') { throw 'Встроенный архив повреждён. Скачайте установщик заново.' }
    $memory = New-Object IO.MemoryStream(,$packed)
    $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Decompress)
    $coreTar = Join-Path $work 'core.tar'
    $file = [IO.File]::Create($coreTar)
    try { $gzip.CopyTo($file) } finally { $file.Dispose(); $gzip.Dispose(); $memory.Dispose() }
    & $tarPath -xf $coreTar -C $work
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось распаковать встроенный пульт.' }
    Remove-Item -LiteralPath $coreTar

    Write-Host '[2/4] Подготавливаю приложения...'
    if (-not $RemoteOnly) {
        $cache = Join-Path $env:LOCALAPPDATA 'StationRemote\cache'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $catalog = @(
            @{ Package='com.conreo.couchytv'; Repo='conreo/couchy-launcher'; Tag='v1.0.6'; Pattern='^Couchy-Launcher-.*\.apk$' },
            @{ Package='org.smarttube.stable'; Repo='yuliskov/SmartTube'; Tag='32.68s'; Pattern='^SmartTube_stable_.*_arm64-v8a\.apk$' },
            @{ Package='com.v2ray.ang'; Repo='2dust/v2rayNG'; Tag='1.9.45'; Pattern='^v2rayNG_.*_arm64-v8a\.apk$' }
        )
        foreach ($app in $catalog) {
            if (-not $UpdateApps -and $preflight -match ('(?m)^APP=' + [regex]::Escape($app.Package) + '\s*$')) { Write-Host "  Уже установлено: $($app.Package)"; continue }
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($app.Repo)/releases/tags/$($app.Tag)" -Headers @{ 'User-Agent'='StationRemote-Installer/2.0' }
            $asset = $release.assets | Where-Object { $_.name -match $app.Pattern } | Select-Object -First 1
            if (-not $asset) { throw "В официальном релизе $($app.Repo) $($app.Tag) не найден подходящий APK." }
            $cached = Join-Path $cache $asset.name
            if (-not (Test-Path -LiteralPath $cached) -or (Get-Item -LiteralPath $cached).Length -ne $asset.size) {
                Write-Host "  Скачиваю $($asset.name), $([math]::Round($asset.size / 1MB, 1)) МБ..."
                Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile ($cached + '.part')
                if ((Get-Item -LiteralPath ($cached + '.part')).Length -ne $asset.size) { throw 'APK скачался не полностью.' }
                Move-Item -LiteralPath ($cached + '.part') -Destination $cached -Force
            }
            if ($asset.digest -and $asset.digest.StartsWith('sha256:') -and (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.digest.Substring(7)) { throw "Не совпал SHA-256 APK: $($asset.name)" }
            Copy-Item -LiteralPath $cached -Destination (Join-Path $work $asset.name)
        }
    }

    Write-Host '[3/4] Устанавливаю пульт и настраиваю автозапуск...'
    $archive = Join-Path $work 'install.tar'
    $files = @(Get-ChildItem -LiteralPath $work -File | ForEach-Object Name)
    & $tarPath --format=ustar -cf $archive -C $work @files
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать архив установки.' }
    $stage = '/data/local/tmp/station-remote-' + [guid]::NewGuid().ToString('N')
    $remoteCommand = "umask 077; mkdir -p $stage && /sbin/busybox tar -xf - -C $stage && /system/bin/sh $stage/install-on-speaker.sh $stage"
    $output = Invoke-StationSsh $remoteCommand ([IO.File]::ReadAllBytes($archive))
    Write-Host $output
    $remoteUrl = [regex]::Match($output, '(?m)^REMOTE_URL=(\S+)').Groups[1].Value
    $setupUrl = [regex]::Match($output, '(?m)^SETUP_URL=(\S+)').Groups[1].Value
    if (-not $remoteUrl) { throw 'Установка не вернула адрес работающего пульта.' }
    $openUrl = if ($setupUrl) { $setupUrl } else { $remoteUrl }
    Write-Host '[4/4] Готово!' -ForegroundColor Green
    Write-Host "Пульт: $remoteUrl"
    if ($setupUrl) { Write-Host "Первый запуск: $setupUrl"; Write-Host 'Откройте эту ссылку и задайте свой пароль. До этого управление закрыто.' }
    else { Write-Host 'Ваш существующий пароль сохранён.' }
    $accessDir = Join-Path $env:LOCALAPPDATA 'StationRemote'
    New-Item -ItemType Directory -Path $accessDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $accessDir 'first-run.txt'), "Пульт: $remoteUrl`r`nОткрыть: $openUrl`r`nПароль задаётся пользователем в браузере.`r`n", (New-Object Text.UTF8Encoding($true)))
    if (-not $NoBrowser) { Start-Process $openUrl }
} catch {
    Write-Host "`nНе удалось завершить установку: $($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) {
        $resolved = [IO.Path]::GetFullPath($work)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^station-remote-[0-9a-f]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
