# hackalice.me/install.ps1 - short address for the YAM Windows installer (https://github.com/nyakokitsu/yam).
# GitHub Pages cannot do HTTP redirects, so this script fetches the current install.ps1 from the
# YAM repository (branch main) and runs it with the same parameters:
#   irm https://hackalice.me/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://hackalice.me/install.ps1))) -RemoveOld
#   & ([scriptblock]::Create((irm https://hackalice.me/install.ps1))) -Platform yandexmini_2
$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 may still default to TLS 1.0; GitHub requires 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$url = "https://raw.githubusercontent.com/nyakokitsu/yam/refs/heads/main/install.ps1"
$installer = [scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -Uri $url))
& $installer @args
