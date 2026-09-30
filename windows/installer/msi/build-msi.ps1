<#
    Build NTPods.msi from a folder made by make-dist.ps1.

    Needs the WiX 5 CLI and its UI + Util extensions:
        dotnet tool install --global wix --version 5.0.2
        wix extension add -g WixToolset.UI.wixext/5.0.2 WixToolset.Util.wixext/5.0.2

    Usage:  .\build-msi.ps1 -Dist <dist folder> [-Version 0.1.0] [-Out NTPods.msi]
    Version is major.minor.build, each part a number (build up to 65535).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dist,
    [string]$Version = '0.1.0',
    [string]$Out = 'NTPods.msi'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$win = Split-Path -Parent (Split-Path -Parent $here)
$Dist = (Resolve-Path $Dist).Path.TrimEnd('\')
if (-not (Test-Path (Join-Path $Dist 'msi-setup.ps1'))) { throw "$Dist has no msi-setup.ps1; rebuild it with make-dist.ps1." }
$icon = Join-Path $win 'winui\NTPods.WinUI\Assets\app.ico'

wix build (Join-Path $here 'NTPods.wxs') -arch x64 `
    -ext WixToolset.UI.wixext/5.0.2 -ext WixToolset.Util.wixext/5.0.2 `
    -d "DistDir=$Dist" -d "Version=$Version" -d "IconFile=$icon" `
    -o $Out
if ($LASTEXITCODE) { throw "wix build failed (exit $LASTEXITCODE)" }
Write-Host "==> $Out ($('{0:N0}' -f ((Get-Item $Out).Length / 1MB)) MB)" -ForegroundColor Green
