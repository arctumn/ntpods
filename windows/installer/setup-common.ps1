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

# The virtual mic needs ACX 1.1 / KMDF 1.31: Windows 11 22H2 (build 22621) or newer.
function Test-MicSupported {
    [Environment]::OSVersion.Version.Build -ge 22621
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
# $root holds driver\, driver-mic\ and tools\devcon.exe (the dist / install dir).
# The packages are copied to $work and signed there, so the files the MSI installed
# stay byte-identical (a repair would otherwise see them as changed).
function Install-NTPodsDrivers([string]$root, [string]$work) {
    $devcon = Join-Path $root 'tools\devcon.exe'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    foreach ($d in 'driver', 'driver-mic') {
        Copy-Item (Join-Path $root $d) $work -Recurse -Force
    }
    $aap = @{ sys = Join-Path $work 'driver\NTPodsAAP.sys'; cat = Join-Path $work 'driver\ntpodsaap.cat'; inf = Join-Path $work 'driver\NTPodsAAP.inf' }
    $mic = @{ sys = Join-Path $work 'driver-mic\AudioCodec.sys'; cat = Join-Path $work 'driver-mic\audiocodec.cat'; inf = Join-Path $work 'driver-mic\AudioCodec.inf' }

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
    Write-Host '==> Signing NTPodsMic...'
    & $sign $mic.sys; & $sign $mic.cat

    # NTPodsAAP: PnP profile driver, via pnputil.
    Write-Host '==> Removing any previously installed NTPodsAAP package...'
    foreach ($oem in (Get-DriverPackages 'NTPodsAAP.inf')) { pnputil /delete-driver $oem /uninstall /force | Out-Null }
    Write-Host '==> Installing NTPodsAAP...'
    # 259 = added, but no matching device yet (AirPods not paired); 3010 = reboot needed.
    Invoke-Tool 'Installing NTPodsAAP (pnputil)' @(0, 259, 3010) { pnputil /add-driver $aap.inf /install }

    # NTPodsMic: ROOT-enumerated device, via devcon.
    Write-Host '==> Removing any existing ROOT\AudioCodec (mic) device...'
    Invoke-Tool 'Removing the old mic device (devcon)' @(0, 1, 2) { & $devcon remove 'ROOT\AudioCodec' }
    # Old mic packages pile up in the driver store otherwise (one per install).
    Remove-MicDriverPackages
    Start-Sleep -Seconds 1
    # The mic driver is built on ACX 1.1 / KMDF 1.31, which only exist from
    # Windows 11 22H2 (build 22621). On older Windows it installs "fine" and then
    # never loads (Code 37), so skip it and say why. An older NTPods that installed
    # it anyway is cleaned up by the two steps above. Everything else works without it.
    if (-not (Test-MicSupported)) {
        Write-Host "==> Skipping NTPodsMic: it needs Windows 11 22H2 or newer (this is build $([Environment]::OSVersion.Version.Build)). Battery, noise control and the rest still work." -ForegroundColor Yellow
        return
    }
    Write-Host '==> Installing NTPodsMic (virtual microphone)...'
    # devcon: 0 = done, 1 = done but a reboot is needed.
    Invoke-Tool 'Installing NTPodsMic (devcon)' @(0, 1) { & $devcon install $mic.inf 'ROOT\AudioCodec' }
    $micDev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'ROOT\AudioCodec' }
    if (-not $micDev) { throw 'devcon reported success, but no ROOT\AudioCodec device exists.' }
}

function Uninstall-NTPodsDrivers([string]$root) {
    $devcon = Join-Path $root 'tools\devcon.exe'
    if (Test-Path $devcon) {
        Write-Host '==> Removing the NTPods microphone device...'
        Invoke-Tool 'Removing the mic device (devcon)' @(0, 1, 2) { & $devcon remove 'ROOT\AudioCodec' }
    }
    foreach ($oem in (Get-DriverPackages 'NTPodsAAP.inf')) {
        Write-Host "==> Removing driver package $oem (NTPodsAAP.inf)"
        pnputil /delete-driver $oem /uninstall /force | Out-Null
    }
    Remove-MicDriverPackages
    Remove-TestCert 'CN=NTPods Test Cert'
}

# Remove the mic driver packages from the driver store. The mic INF is named after
# the WDK sample it came from, so match the provider too; older builds still
# carried the sample's VS_Microsoft / LibrePods.
function Remove-MicDriverPackages {
    foreach ($oem in (Get-DriverPackages 'audiocodec.inf' @('NTPods', 'LibrePods', 'VS_Microsoft'))) {
        Write-Host "==> Removing driver package $oem (audiocodec.inf)"
        pnputil /delete-driver $oem /uninstall /force | Out-Null
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
