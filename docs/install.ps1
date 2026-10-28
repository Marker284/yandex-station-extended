# hackalice.me/install.ps1 - short address for the YAM Windows installer (https://github.com/nyakokitsu/yam).
# GitHub Pages cannot do HTTP redirects, so this script fetches the current install.ps1 from the
# YAM repository and runs it with the same parameters.
# Pinned to v0.1.19: the installer on main belongs to YAM v2, which has no release yet.
#   irm https://hackalice.me/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://hackalice.me/install.ps1))) -Uninstall
#   & ([scriptblock]::Create((irm https://hackalice.me/install.ps1))) -Version 0.1.13
param(
    [string]$Version,
    [string]$Prefix,
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 may still default to TLS 1.0; GitHub requires 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$url = "https://raw.githubusercontent.com/nyakokitsu/yam/refs/tags/v0.1.19/install.ps1"
$installer = [scriptblock]::Create((Invoke-RestMethod -UseBasicParsing -Uri $url))
& $installer @PSBoundParameters
