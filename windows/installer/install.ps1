<#
    NTPods for Windows — one-shot installer (the zip install; NTPods.msi does the
    same thing with a normal setup wizard).

    Installs BOTH kernel drivers (test-signed on the fly):
      • NTPodsAAP  — opens the AirPods AAP L2CAP channel (battery, ANC, mic, …).
      • NTPodsMic  — a virtual microphone so any app can use the AirPods mic.
                     Two drivers exist: ACX (default on Windows 11 22H2+) and
                     PortCls (Windows 10 2004+). -MicDriver acx|portcls overrides.
    Then copies the daemon + WinUI app to %LOCALAPPDATA%\NTPods, registers the
    two elevated helper tasks (driver recovery, mic rename) and adds the apps to
    startup (the WinUI app launches minimised to the tray).

    RUN AS ADMINISTRATOR, and only AFTER you have:
      1. Backed up your BitLocker recovery key.
      2. Disabled Secure Boot in your firmware/BIOS.
      3. Enabled test signing:  bcdedit /set testsigning on   (then rebooted).

    Everything it needs is in this folder: driver packages (with catalogs), devcon
    and the apps. Nothing from Visual Studio, the Windows SDK or the WDK has to be
    installed — the drivers are signed with PowerShell's own Authenticode support.

    Usage (elevated):  powershell -ExecutionPolicy Bypass -File .\install.ps1
    With BitLocker on it asks you to confirm the recovery key is saved; -Yes
    skips that question (unattended installs).
      .\install.ps1 -MicDriver portcls     use the PortCls mic on Windows 11 too
#>
param([switch]$Yes, [ValidateSet('auto', 'acx', 'portcls')][string]$MicDriver = 'auto')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'setup-common.ps1')
$dest = Join-Path $env:LOCALAPPDATA 'NTPods'
$sid = Get-CurrentUserSid

# ---- 0. preflight: fail BEFORE touching certificates or drivers -------------
if (-not (Test-Admin)) { throw 'Run this from an ADMINISTRATOR PowerShell.' }
$bitlocker = Test-BitLocker
if (-not (Test-TestMode)) {
    $secureBoot = switch (Test-SecureBoot) {
        $true { 'Secure Boot is ON on this PC, so turn it off first.' }
        $false { 'Secure Boot is already off.' }
        default { "Couldn't read the Secure Boot state." }
    }
    $bl = if ($bitlocker) { "BitLocker is ON for $env:SystemDrive. $script:BitLockerAdvice" } else { 'BitLocker is off for the system drive.' }
    throw @"
Test Mode is not active, so Windows would refuse to load the NTPods drivers.
  1. $bl
  2. Disable Secure Boot in your firmware/BIOS (while it is on, bcdedit refuses).
     $secureBoot
  3. In an admin PowerShell:  bcdedit /set testsigning on
  4. Reboot ("Test Mode" shows in the bottom-right corner), then run this again.
"@
}
# Test Mode is on, but whoever turns it (or Secure Boot) back off later hits the
# same BitLocker prompt, so make sure the key is saved before going further.
if ($bitlocker) {
    Write-Host "BitLocker is ON for $env:SystemDrive.`n$script:BitLockerAdvice" -ForegroundColor Yellow
    if (-not $Yes) {
        $a = Read-Host 'Is your BitLocker recovery key saved somewhere other than this PC? (y/N)'
        if ($a -notmatch '^(y|yes|s|sim)$') { throw 'Stopped: save the BitLocker recovery key first, then run this again.' }
    }
}

$required = @(
    'driver\NTPodsAAP.sys', 'driver\ntpodsaap.cat', 'driver\NTPodsAAP.inf',
    'driver-mic\NTPodsMicPC.sys', 'driver-mic\ntpodsmicpc.cat', 'driver-mic\NTPodsMicPC.inf',
    'driver-mic-acx\AudioCodec.sys', 'driver-mic-acx\audiocodec.cat', 'driver-mic-acx\AudioCodec.inf',
    'tools\devcon.exe', 'ntpodsd.exe', 'avcodec-61.dll', 'avutil-59.dll', 'swresample-5.dll',
    'winui\ntpods-winui.exe', 'fix-driver.ps1', 'rename-mic.ps1'
) | ForEach-Object { Join-Path $here $_ }
$missing = @($required | Where-Object { -not (Test-Path $_) })
if ($missing) {
    throw "This install folder is incomplete. Download the release again. Missing:`n  " + ($missing -join "`n  ")
}

# ---- 1. take over an older LibrePods install ---------------------------------
Stop-NTPods
Remove-LegacyLibrePods $sid $env:LOCALAPPDATA $env:APPDATA
Remove-SetupLeftovers $env:LOCALAPPDATA

# ---- 2. both drivers (test-signed here, then pnputil / devcon) ---------------
$work = Join-Path $env:TEMP "NTPods-drivers-$(Get-Random)"
try { Install-NTPodsDrivers $here $work $MicDriver }
finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

# ---- 3. copy the apps -------------------------------------------------------
# The daemon owns the driver + AAP session + mic; the WinUI app is its IPC client.
Write-Host "==> Copying the apps to $dest"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($f in 'ntpodsd.exe', 'avcodec-61.dll', 'avutil-59.dll', 'swresample-5.dll', 'fix-driver.ps1', 'rename-mic.ps1') {
    Copy-Item (Join-Path $here $f) $dest -Force
}
# The WinUI app ships as a self-contained folder.
Copy-Item (Join-Path $here 'winui') $dest -Recurse -Force
# Files from a downloaded zip carry the internet zone mark; clear it on the
# installed copy so startup and the scheduled tasks don't get blocked or prompted.
Get-ChildItem $dest -Recurse -File | Unblock-File

# ---- 4. elevated on-demand helper tasks -------------------------------------
Register-NTPodsTasks $dest $sid

# ---- 5. auto-start at login -------------------------------------------------
# The daemon is the always-on background process (per-user, in the session — NOT a
# SYSTEM service, which couldn't touch the user's audio/mic). The WinUI app starts
# minimised to the tray (--tray) and is the UI; closing its window hides it back.
# Same Run values the app's own "Start with Windows" setting uses.
Write-Host '==> Adding the daemon + WinUI app to startup...'
$startup = Get-StartupDir $env:APPDATA
foreach ($l in 'NTPods Daemon.lnk', 'NTPods.lnk') {   # older installs used shortcuts
    Remove-Item (Join-Path $startup $l) -Force -ErrorAction SilentlyContinue
}
Set-RunValues $sid (Join-Path $dest 'ntpodsd.exe') (Join-Path $dest 'winui\ntpods-winui.exe')

Write-Host ''
Write-Host '==> Done. A reboot is needed to finish the driver install.' -ForegroundColor Green
Write-Host '    After reboot, connect your AirPods — the WinUI app (tray) shows battery'
Write-Host '    + Noise Control, and the NTPods microphone appears in Sound > Input'
Write-Host '    (and in Discord etc.), renamed to your AirPods once they connect.'
