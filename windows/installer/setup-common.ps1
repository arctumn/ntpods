<#
    Shared install steps for install.ps1 (zip install) and msi-setup.ps1 (the MSI's
    custom actions). Dot-source it; it only defines functions.

    Everything per-user takes the user's SID and folders explicitly, because the
    MSI runs these steps as SYSTEM, where HKCU and $env:LOCALAPPDATA belong to
    SYSTEM and not to the person installing.
#>

$script:RunKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'

function Get-CurrentUserSid {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Test-signed drivers only load when the RUNNING boot has test signing on.
# SystemStartOptions describes the current boot (bcdedit shows the next one), so
# this also catches "turned it on but didn't reboot yet".
function Test-TestMode {
    $opts = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').SystemStartOptions
    $opts -match '\bTESTSIGNING\b'
}

# Secure Boot on means bcdedit refuses `testsigning on`, so it's worth naming when
# Test Mode is off. $null when it can't be read (legacy BIOS, or not elevated).
function Test-SecureBoot {
    try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
}

# BitLocker protection on the system drive. Changing Secure Boot or the boot
# options (testsigning) can make it ask for the recovery key at the next boot.
# WMI rather than Get-BitLockerVolume (missing on some editions) or manage-bde
# (its output is translated). Needs admin; $false when it can't be read.
function Test-BitLocker {
    try {
        $v = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' `
            -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        [bool]($v | Where-Object { $_.ProtectionStatus -eq 1 })
    } catch { $false }
}

$script:BitLockerAdvice = @'
Save your BitLocker recovery key before changing Secure Boot or Test Mode:
changing either can make Windows ask for it at the next boot, and without it
you lose access to this drive. Find it at https://aka.ms/myrecoverykey (if it
is saved to your Microsoft account) or print it from an admin terminal with:
  manage-bde -protectors -get C:
'@

# The virtual mic (PortCls) needs Windows 10 2004 (build 19041) or newer, the
# floor its INF declares (ExAllocatePool2).
function Test-MicSupported {
    [Environment]::OSVersion.Version.Build -ge 19041
}

# There are two mic drivers with the same \\.\NTPodsMic control device, so the
# daemon works with either:
#   acx      ACX (drivers/mic), the default on Windows 11 22H2 (build 22621)+;
#            it needs ACX 1.1 / KMDF 1.31, which older Windows doesn't have.
#   portcls  PortCls/WaveRT (drivers/mic-portcls), Windows 10 2004+.
# 'auto' picks by OS. Asking for ACX where it can't load falls back to PortCls.
function Resolve-MicDriver([string]$choice) {
    $build = [Environment]::OSVersion.Version.Build
    $acxOk = $build -ge 22621
    switch ($choice) {
        'portcls' { return 'portcls' }
        'acx' {
            if ($acxOk) { return 'acx' }
            Write-Host "==> The ACX mic needs Windows 11 22H2 or newer (this is build $build); using the PortCls mic instead." -ForegroundColor Yellow
            return 'portcls'
        }
        default { if ($acxOk) { return 'acx' } else { return 'portcls' } }
    }
}

# Run a native tool, echo its output, and fail on an exit code outside $ok.
# (Native stderr must not become a terminating error under 'Stop', so the
# preference is relaxed for the call itself.)
function Invoke-Tool([string]$what, [int[]]$ok, [scriptblock]$cmd) {
    $ErrorActionPreference = 'Continue'
    $out = & $cmd 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($out.Trim()) { Write-Host $out.TrimEnd() }
    if ($ok -notcontains $code) { throw "$what failed (exit code $code)." }
}

function Stop-NTPods {
    Get-Process -Name 'ntpods-winui', 'ntpodsd', 'librepods-winui', 'librepodsd', 'librepods-tray', 'librepods' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# Published names (oemNN.inf) of driver-store packages with this original INF
# name (and provider, when given). Uses DISM rather than parsing `pnputil
# /enum-drivers`, whose labels are translated on non-English Windows.
function Get-DriverPackages([string]$infName, [string[]]$provider) {
    @(Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object {
            (Split-Path -Leaf $_.OriginalFileName) -eq $infName -and
            (-not $provider -or $provider -contains $_.ProviderName)
        } | ForEach-Object { $_.Driver })
}

function Get-StartupDir([string]$appData) {
    Join-Path $appData 'Microsoft\Windows\Start Menu\Programs\Startup'
}

function Remove-RunValues([string]$userSid, [string[]]$names) {
    $key = "Registry::HKEY_USERS\$userSid\$script:RunKeyPath"
    foreach ($n in $names) { Remove-ItemProperty $key -Name $n -ErrorAction SilentlyContinue }
}

function Set-RunValues([string]$userSid, [string]$daemonExe, [string]$winuiExe) {
    $key = "Registry::HKEY_USERS\$userSid\$script:RunKeyPath"
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty $key -Name 'NTPods Daemon' -Value "`"$daemonExe`""
    Set-ItemProperty $key -Name 'NTPods' -Value "`"$winuiExe`" --tray"
}

# Remove every copy of a test certificate from the machine stores. Uses the
# X509Store API (the same one that adds them): piping the Cert: provider into
# Remove-Item left all of them in place when run as SYSTEM from the MSI.
function Remove-TestCert([string]$subject) {
    foreach ($name in 'My', 'Root', 'TrustedPublisher') {
        $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
        try {
            $s.Open('ReadWrite')
            $old = @($s.Certificates | Where-Object { $_.Subject -eq $subject })
            foreach ($c in $old) { $s.Remove($c) }
            if ($old) { Write-Host "==> Removed $($old.Count) '$subject' from $name" }
        } catch {
            Write-Warning "Could not clean '$subject' from ${name}: $_"
        } finally { $s.Close() }
    }
}

# ---- older installs -----------------------------------------------------------
# NTPods used to be called LibrePods (for Windows). Keep the user's settings and
# heart-rate history, and remove the old driver, tasks, startup entries and test
# certificate so the two never fight over the AirPods.
function Remove-LegacyLibrePods([string]$userSid, [string]$localAppData, [string]$appData) {
    $legacy = Join-Path $localAppData 'LibrePods'
    $data = Join-Path $localAppData 'NTPods'
    if (Test-Path $legacy) {
        Write-Host "==> Moving your settings and heart-rate history from $legacy"
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        foreach ($f in 'winui-settings.json', 'ui.pref', 'micname.txt', 'heart-rate.sqlite3', 'heart-rate.sqlite3-wal', 'heart-rate.sqlite3-shm') {
            $from = Join-Path $legacy $f; $to = Join-Path $data $f
            if ((Test-Path $from) -and -not (Test-Path $to)) { Copy-Item $from $to }
        }
    }
    foreach ($t in 'LibrePods Fix Driver', 'LibrePods Rename Mic') {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-RunValues $userSid 'LibrePods', 'LibrePods Daemon'
    $startup = Get-StartupDir $appData
    foreach ($l in 'LibrePods Daemon.lnk', 'LibrePods.lnk') {
        Remove-Item (Join-Path $startup $l) -Force -ErrorAction SilentlyContinue
    }
    foreach ($oem in (Get-DriverPackages 'LibrePodsAAP.inf')) {
        Write-Host "==> Removing the old LibrePods AAP driver ($oem)"
        pnputil /delete-driver $oem /uninstall /force | Out-Null
    }
    Remove-TestCert 'CN=LibrePods Test Cert'
    if (Test-Path $legacy) { Remove-Item $legacy -Recurse -Force -ErrorAction SilentlyContinue }
    # The old tray app kept a device list in %APPDATA%\LibrePods; nothing reads it now.
    Remove-Item (Join-Path $appData 'LibrePods') -Recurse -Force -ErrorAction SilentlyContinue
}

# Folders earlier installs left behind: driver work folders from an install that
# didn't clean up after itself (every zip install before this one), and the
# package folders of the old per-driver scripts. $localAppData\Temp is the user's
# %TEMP%, which the MSI (running as SYSTEM) can't get from its own environment.
function Remove-SetupLeftovers([string]$localAppData) {
    $temps = @((Join-Path $localAppData 'Temp'), $env:TEMP) | Select-Object -Unique
    foreach ($t in $temps) {
        Get-ChildItem $t -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'NTPods-drivers-*' -or $_.Name -like 'LibrePods-drivers-*' -or
                           $_.Name -in 'NTPodsMicPkg', 'LibrePodsMicPkg' } |
            ForEach-Object {
                Write-Host "==> Removing leftover $($_.FullName)"
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
    }
    Get-ChildItem (Join-Path $env:ProgramData 'NTPods') -Directory -Filter 'drivers-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

# A zip install (install.ps1) keeps the programs in %LOCALAPPDATA%\NTPods and
# starts them from the Startup folder. The MSI calls this so only one copy is left.
# Settings, logs and heart-rate history in that folder stay.
function Remove-ZipInstall([string]$localAppData, [string]$appData) {
    $dir = Join-Path $localAppData 'NTPods'
    foreach ($f in 'ntpodsd.exe', 'avcodec-61.dll', 'avutil-59.dll', 'swresample-5.dll', 'fix-driver.ps1', 'rename-mic.ps1') {
        Remove-Item (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'winui') -Recurse -Force -ErrorAction SilentlyContinue
    $startup = Get-StartupDir $appData
    foreach ($l in 'NTPods Daemon.lnk', 'NTPods.lnk') {
        Remove-Item (Join-Path $startup $l) -Force -ErrorAction SilentlyContinue
    }
}

# ---- drivers ------------------------------------------------------------------
# $root holds driver\, driver-mic\ (PortCls), driver-mic-acx\ and tools\devcon.exe
# (the dist / install dir). The packages are copied to $work and signed there, so
# the files the MSI installed stay byte-identical (a repair would otherwise see
# them as changed). $micDriver: auto | acx | portcls, see Resolve-MicDriver.
function Install-NTPodsDrivers([string]$root, [string]$work, [string]$micDriver = 'auto') {
    $devcon = Join-Path $root 'tools\devcon.exe'
    $micKind = Resolve-MicDriver $micDriver
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    foreach ($d in 'driver', 'driver-mic', 'driver-mic-acx') {
        Copy-Item (Join-Path $root $d) $work -Recurse -Force
    }
    $aap = @{ sys = Join-Path $work 'driver\NTPodsAAP.sys'; cat = Join-Path $work 'driver\ntpodsaap.cat'; inf = Join-Path $work 'driver\NTPodsAAP.inf' }
    $mic = if ($micKind -eq 'acx') {
        @{ name = 'ACX'; hwid = 'ROOT\AudioCodec'
           sys = Join-Path $work 'driver-mic-acx\AudioCodec.sys'; cat = Join-Path $work 'driver-mic-acx\audiocodec.cat'; inf = Join-Path $work 'driver-mic-acx\AudioCodec.inf' }
    } else {
        @{ name = 'PortCls'; hwid = 'ROOT\NTPodsMicPC'
           sys = Join-Path $work 'driver-mic\NTPodsMicPC.sys'; cat = Join-Path $work 'driver-mic\ntpodsmicpc.cat'; inf = Join-Path $work 'driver-mic\NTPodsMicPC.inf' }
    }

    # Test code-signing cert, trusted for driver loading. Reuse the one from an
    # earlier run instead of piling up a new one every time.
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq 'CN=NTPods Test Cert' -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) {
        Write-Host '==> Reusing the NTPods test code-signing certificate...'
    } else {
        Write-Host '==> Creating a test code-signing certificate...'
        $cert = New-SelfSignedCertificate -Type CodeSigningCert `
            -Subject 'CN=NTPods Test Cert' `
            -CertStoreLocation Cert:\LocalMachine\My `
            -KeyUsage DigitalSignature -KeyExportPolicy Exportable
    }
    Write-Host '==> Trusting it for driver loading...'
    foreach ($name in 'Root', 'TrustedPublisher') {
        $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
        $s.Open('ReadWrite'); $s.Add($cert); $s.Close()
    }

    # The catalogs are prebuilt (inf2cat, at release time) and cover the .sys by its
    # Authenticode hash, which embedding a signature in the .sys does not change.
    $sign = {
        param($path)
        $r = Set-AuthenticodeSignature -FilePath $path -Certificate $cert -HashAlgorithm SHA256
        if (-not $r.SignerCertificate) { throw "Could not sign ${path}: $($r.StatusMessage)" }
        if ($r.Status -ne 'Valid') { Write-Warning "$(Split-Path -Leaf $path): signed, but reported $($r.Status): $($r.StatusMessage)" }
    }
    Write-Host '==> Signing NTPodsAAP...'
    & $sign $aap.sys; & $sign $aap.cat
    Write-Host "==> Signing NTPodsMic ($($mic.name))..."
    & $sign $mic.sys; & $sign $mic.cat

    # NTPodsAAP: PnP profile driver, via pnputil.
    Write-Host '==> Removing any previously installed NTPodsAAP package...'
    foreach ($oem in (Get-DriverPackages 'NTPodsAAP.inf')) { pnputil /delete-driver $oem /uninstall /force | Out-Null }
    Write-Host '==> Installing NTPodsAAP...'
    # 259 = added, but no matching device yet (AirPods not paired); 3010 = reboot needed.
    Invoke-Tool 'Installing NTPodsAAP (pnputil)' @(0, 259, 3010) { pnputil /add-driver $aap.inf /install }

    # NTPodsMic: ROOT-enumerated device, via devcon. Remove both kinds first, so
    # switching between ACX and PortCls never leaves two mics side by side.
    Write-Host '==> Removing any existing mic device...'
    Invoke-Tool 'Removing the old mic device (devcon)' @(0, 1, 2) { & $devcon remove 'ROOT\NTPodsMicPC' }
    Invoke-Tool 'Removing the old ACX mic device (devcon)' @(0, 1, 2) { & $devcon remove 'ROOT\AudioCodec' }
    # Old mic packages pile up in the driver store otherwise (one per install).
    Remove-MicDriverPackages
    Start-Sleep -Seconds 1
    # On older Windows the INF has no matching section and the device would never
    # start, so skip it and say why. Everything else works without it.
    if (-not (Test-MicSupported)) {
        Write-Host "==> Skipping NTPodsMic: it needs Windows 10 2004 or newer (this is build $([Environment]::OSVersion.Version.Build)). Battery, noise control and the rest still work." -ForegroundColor Yellow
        return
    }
    Write-Host "==> Installing NTPodsMic, $($mic.name) driver (virtual microphone)..."
    # devcon: 0 = done, 1 = done but a reboot is needed.
    Invoke-Tool 'Installing NTPodsMic (devcon)' @(0, 1) { & $devcon install $mic.inf $mic.hwid }
    $micDev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains $mic.hwid }
    if (-not $micDev) { throw "devcon reported success, but no $($mic.hwid) device exists." }
}

function Uninstall-NTPodsDrivers([string]$root) {
    $devcon = Join-Path $root 'tools\devcon.exe'
    if (Test-Path $devcon) {
        Write-Host '==> Removing the NTPods microphone device...'
        Invoke-Tool 'Removing the mic device (devcon)' @(0, 1, 2) { & $devcon remove 'ROOT\NTPodsMicPC' }
        Invoke-Tool 'Removing the old ACX mic device (devcon)' @(0, 1, 2) { & $devcon remove 'ROOT\AudioCodec' }
    }
    foreach ($oem in (Get-DriverPackages 'NTPodsAAP.inf')) {
        Write-Host "==> Removing driver package $oem (NTPodsAAP.inf)"
        pnputil /delete-driver $oem /uninstall /force | Out-Null
    }
    Remove-MicDriverPackages
    Remove-TestCert 'CN=NTPods Test Cert'
}

# Remove every mic driver package from the driver store, PortCls and ACX alike.
# The ACX INF is named after the WDK sample it came from, so
# match the provider too; older builds still carried the sample's VS_Microsoft /
# LibrePods.
function Remove-MicDriverPackages {
    foreach ($p in @(@('NTPodsMicPC.inf', $null), @('audiocodec.inf', @('NTPods', 'LibrePods', 'VS_Microsoft')))) {
        foreach ($oem in (Get-DriverPackages $p[0] $p[1])) {
            Write-Host "==> Removing driver package $oem ($($p[0]))"
            pnputil /delete-driver $oem /uninstall /force | Out-Null
        }
    }
}

# ---- elevated on-demand helper tasks -----------------------------------------
# The daemon runs unelevated and fires these with `schtasks /run`, which runs them
# elevated WITHOUT a UAC prompt:
#   • NTPods Fix Driver — recover the AAP devnode from Code 38 without a reboot,
#     after repeated driver-open failures (daemon/src/devnode.rs). It re-checks
#     the devnode and no-ops when healthy.
#   • NTPods Rename Mic — show the mic under the connected device's name; the
#     daemon writes it to micname.txt first (daemon/src/rename.rs). Idempotent.
# They run as the user (not SYSTEM) so that user can start them and they see the
# user's %LOCALAPPDATA%.
function Register-NTPodsTasks([string]$scriptDir, [string]$userSid) {
    $user = (New-Object Security.Principal.SecurityIdentifier($userSid)).Translate([Security.Principal.NTAccount]).Value
    Write-Host "==> Registering the elevated helper tasks for $user..."
    foreach ($t in @(
            @('NTPods Fix Driver', 'fix-driver.ps1', 'Recover the NTPods AAP devnode from Code 38 (no reboot).'),
            @('NTPods Rename Mic', 'rename-mic.ps1', 'Rename the NTPods virtual mic to the connected device name.'))) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $scriptDir $t[1])`""
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable
        Register-ScheduledTask -TaskName $t[0] -Action $action -Principal $principal `
            -Settings $settings -Description $t[2] -Force | Out-Null
    }
}

function Unregister-NTPodsTasks {
    foreach ($t in 'NTPods Fix Driver', 'NTPods Rename Mic') {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
}
