<#
    rename-mic.ps1 - show the NTPodsMic virtual microphone under the connected
    device's name, e.g. "AirPods Pro de Pedro (NTPods)" in Sound settings and
    Discord. NEEDS ADMIN (writes HKLM).

    Two ways in:
      * The "NTPods Rename Mic" scheduled task (RunLevel Highest), which
        install.ps1 registers. The daemon writes the name to
        %LOCALAPPDATA%\NTPods\micname.txt and fires the task with
        `schtasks /run` (daemon/src/rename.rs). No -Name, runs hidden.
      * By hand, elevated:   .\rename-mic.ps1 "AirPods Pro de Pedro"

    The endpoint is matched by the hardware id of the device behind it
    (ROOT\NTPodsMicPC, or ROOT\AudioCodec for the old ACX mic), not by its
    name, so it still matches after a rename. The
    name lives in PKEY_Device_DeviceDesc; Windows shows "<DeviceDesc> (<interface
    name>)". Idempotent: when the name is already right it changes nothing and
    does NOT restart the audio service, so the daemon can fire it on every connect.
    Every run appends to %LOCALAPPDATA%\NTPods\rename.log.
#>
param([string]$Name)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:LOCALAPPDATA 'NTPods'
$log = Join-Path $dir 'rename.log'
function Log([string]$msg) {
    $line = '{0:yyyy-MM-ddTHH:mm:ss.fffZ} {1}' -f (Get-Date).ToUniversalTime(), $msg  # UTC, like daemon.log
    Write-Host $line
    try {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 256KB) { Clear-Content $log }
        Add-Content -Path $log -Value $line -Encoding UTF8
    } catch { }
}

if (-not $Name) {
    $file = Join-Path $dir 'micname.txt'
    if (-not (Test-Path $file)) { Log "no -Name given and $file does not exist"; exit 1 }
    $Name = (Get-Content $file -Raw -Encoding UTF8).Trim()
}
if (-not $Name) { Log 'empty name, nothing to do'; exit 1 }

$base    = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
$hwKey   = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6},8'   # hardware id of the backing device
$ifKey   = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'   # PKEY_DeviceInterface_FriendlyName
$descKey = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'   # PKEY_Device_DeviceDesc

# Values are normally REG_SZ; tolerate the REG_BINARY PROPVARIANT form (4-byte
# type tag + UTF-16) that some endpoints use.
function Read-Str($key, [string]$valueName) {
    $v = $key.GetValue($valueName)
    if ($v -is [byte[]]) {
        if ($v.Length -le 4) { return '' }
        return [Text.Encoding]::Unicode.GetString($v, 4, $v.Length - 4).TrimEnd([char]0)
    }
    if ($null -eq $v) { return '' }
    return [string]$v
}

# Any failure below ends up in rename.log (the task runs hidden, so this is the
# only place it shows).
trap { Log "failed: $_"; exit 1 }

$root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($base)
if (-not $root) { Log "cannot open HKLM\$base"; exit 1 }
$matched = 0; $changed = 0
try {
    foreach ($id in $root.GetSubKeyNames()) {
        $props = $root.OpenSubKey("$id\Properties")
        if (-not $props) { continue }
        try {
            $hw    = Read-Str $props $hwKey
            $iface = Read-Str $props $ifKey
            $desc  = Read-Str $props $descKey
        } finally { $props.Close() }
        if ($hw -notin 'ROOT\NTPodsMicPC', 'ROOT\AudioCodec' -and $iface -notlike '*NTPods*') { continue }

        $matched++
        if ($desc -ceq $Name) { Log "$id already '$Name'"; continue }
        # The key belongs to Audiosrv/TrustedInstaller; Administrators only get
        # SetValue on it, so OpenSubKey(..., $true) (full KEY_WRITE) is denied even
        # elevated. Ask for exactly what the ACL grants.
        $w = $root.OpenSubKey("$id\Properties",
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Security.AccessControl.RegistryRights]::QueryValues -bor [Security.AccessControl.RegistryRights]::SetValue)
        try { $w.SetValue($descKey, $Name, [Microsoft.Win32.RegistryValueKind]::String) } finally { $w.Close() }
        Log "$id '$desc' -> '$Name'"
        $changed++
    }
} finally { $root.Close() }

if (-not $matched) { Log 'no NTPods capture endpoint found - is the NTPodsMic driver installed?'; exit 1 }
if ($changed) {
    # Apps only pick up the new name after the endpoint service re-reads it.
    Log 'restarting AudioEndpointBuilder (brief audio drop)'
    Restart-Service -Name AudioEndpointBuilder -Force
}
