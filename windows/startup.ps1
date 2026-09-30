<#
    startup.ps1 - make a NTPods Windows app launch at user login (or remove it).

    Per-user, NO admin needed. Copies the exe to a stable location
    (%LOCALAPPDATA%\NTPods) and drops a shortcut in the Startup folder, so it
    survives even if the WSL build target is cleaned.

    Install (default = the WinUI app):
        .\startup.ps1
        .\startup.ps1 -Exe "C:\path\to\ntpods-winui.exe"
    Remove:
        .\startup.ps1 -Remove
#>
param(
    [string]$Exe       = "$env:LOCALAPPDATA\NTPods\ntpods-winui.exe",
    [string]$Arguments = '--tray',   # WinUI starts hidden to the tray at login
    [string]$Name      = 'NTPods',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$startup = [Environment]::GetFolderPath('Startup')
$lnk     = Join-Path $startup "$Name.lnk"

if ($Remove) {
    if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "Removed $lnk" }
    else                { Write-Host "No startup shortcut to remove." }
    return
}

if (-not (Test-Path $Exe)) { throw "Exe not found: $Exe (copy it there first, or pass -Exe)" }

$ws       = New-Object -ComObject WScript.Shell
$s        = $ws.CreateShortcut($lnk)
$s.TargetPath       = $Exe
$s.Arguments        = $Arguments
$s.WorkingDirectory = Split-Path $Exe
$s.Description      = 'NTPods AirPods control'
$s.Save()

Write-Host "==> Startup shortcut created:"
Write-Host "    $lnk  ->  $Exe"
Write-Host "It will launch at your next login. To undo: .\startup.ps1 -Remove"
