<#
Установка ТВ-набора на Яндекс Станцию 1 с компьютера (Windows PowerShell 5.1+):
веб-пульт (порт 8080), Couchy Launcher, SmartTube и v2rayNG.

Нужно заранее: root и SSH через AliceBridge (dropbear, порт 22), Entware на колонке, OpenSSH-клиент
в Windows. Без SSH-ключа пароль root спросят дважды: при отправке архива и при установке.

Пример:
  powershell -ExecutionPolicy Bypass -File install.ps1 -Ip 192.168.1.50
  powershell -ExecutionPolicy Bypass -File install.ps1 -Ip 192.168.1.50 -Key $HOME\.ssh\id_ed25519 -BindAddress 192.168.1.20
-BindAddress нужен, если на компьютере включён VPN и колонка без него недоступна.
#>
param(
    [Parameter(Mandatory = $true)][string]$Ip,
    [string]$Key,
    [string]$BindAddress
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path $env:TEMP 'tvpack'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$work\tvpack" | Out-Null

function Get-LatestApk($repo, $pattern, $tag) {
    $path = if ($tag) { "tags/$tag" } else { 'latest' }
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/$path" -Headers @{ 'User-Agent' = 'tvpack' }
    $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "в последнем релизе $repo нет файла по шаблону $pattern" }
    Write-Host "[*] $repo $($rel.tag_name): $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) МБ)"
    Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile "$work\tvpack\$($asset.name)"
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Get-LatestApk 'conreo/couchy-launcher' '^Couchy-Launcher-.*\.apk$'
Get-LatestApk 'yuliskov/SmartTube' '^SmartTube_stable_.*_arm64-v8a\.apk$'
# v2rayNG закреплён на 1.9.45: проверено на Android 6 (minSdk 21); Happ и Incy требуют Android 7+
Get-LatestApk '2dust/v2rayNG' '^v2rayNG_.*_arm64-v8a\.apk$' '1.9.45'

# файлы пульта — с переводами строк LF, иначе sh на колонке их не выполнит
foreach ($f in 'index.html', 'k', 'remote.conf', 'remote.sh', 'install-on-speaker.sh') {
    $text = [IO.File]::ReadAllText((Join-Path $here $f)).Replace("`r`n", "`n")
    [IO.File]::WriteAllText("$work\tvpack\$f", $text, (New-Object Text.UTF8Encoding($false)))
}
tar -cf "$work\tvpack.tar" -C $work tvpack
if ($LASTEXITCODE) { throw 'не удалось собрать архив' }

$sshArgs = @()
if ($Key) { $sshArgs += @('-i', "`"$Key`"") }
if ($BindAddress) { $sshArgs += @('-o', "BindAddress=$BindAddress") }
$ssh = "ssh $($sshArgs -join ' ') root@$Ip"

Write-Host '[*] отправляю архив на колонку'
cmd /c "$ssh ""rm -rf /data/local/tmp/tvpack && /sbin/busybox tar -xf - -C /data/local/tmp"" < ""$work\tvpack.tar"""
if ($LASTEXITCODE) { throw 'не удалось отправить архив по SSH' }

Write-Host '[*] устанавливаю на колонке'
cmd /c "$ssh ""/system/bin/sh /data/local/tmp/tvpack/install-on-speaker.sh"""
if ($LASTEXITCODE) { throw 'установка на колонке завершилась с ошибкой' }

Remove-Item -Recurse -Force $work
