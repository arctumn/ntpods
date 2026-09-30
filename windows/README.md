# NTPods on Windows

Open-source AirPods control for Windows: battery, noise control, ear detection,
conversational awareness, volume/mute, hearing aid, device rename, the AirPods'
**hi-res microphone as a real Windows input** so any app can use it, and
**heart-rate monitoring** on AirPods Pro 3 (live BPM, a graph and your history).

It has these parts:

1. **`NTPodsAAP` kernel driver** ([`drivers/aap`](drivers/aap)) — opens the Apple
   Accessory Protocol (AAP) L2CAP channel to the AirPods in kernel mode, which
   normal Windows apps cannot do, and exposes it via IOCTLs.
2. **`NTPodsMic` kernel driver** ([`drivers/mic`](drivers/mic)) — a virtual audio
   device that publishes the AirPods' decoded hi-res mic as a Windows capture
   endpoint (Teams / Zoom / Discord / OBS …).
3. **`ntpodsd` daemon** ([`daemon`](daemon)) — owns both drivers, the AAP session
   and the mic pipeline (AAC-ELD decode), and serves UI clients over named-pipe IPC.
   It holds the authoritative state.
4. **`ntpods-winui` app** ([`winui`](winui)) — the native **WinUI 3** client; it
   lives in the system tray (closing hides it there) and is an IPC client of the
   daemon. It's what you run day-to-day.

Works with any AirPods (2/3, Pro 1/2/3, Max) and Apple Beats — the driver binds
to the AAP service every AirPod advertises, not to a specific model. Features
shown depend on the model (e.g. only Pro/Max have noise control).

---

## 1. Install (one-time)

> ⚠️ The drivers aren't signed by Microsoft, so Windows must run in **Test Mode**
> (same requirement as the commercial MagicAAP driver). This lowers a security
> setting. **Advanced users only** — a system restore point is recommended.

### a) Turn on Test Mode
1. Back up your **BitLocker recovery key** (if BitLocker is on) and make a
   **restore point**.
2. Disable **Secure Boot** in your firmware/BIOS (it blocks test-signed drivers).
3. In an **admin** PowerShell: `bcdedit /set testsigning on` → **reboot**.
   You should see "Test Mode" in the bottom-right of the desktop.

### b) Install with the MSI (recommended)
Download **`NTPods.msi`** from the
[`nightly` release](https://github.com/arctumn/ntpods/releases/tag/nightly)
(rebuilt on every push to `main`) and run it. It stops if Test Mode isn't on.
You can choose:

- **Drivers**: test-signs and installs both drivers on this PC. Leave it on.
- **Desktop shortcut**
- **Start with Windows**: starts NTPods in the tray when you sign in (you can
  change this later in the app's settings).

It installs to `C:\Program Files\NTPods`, registers the driver-recovery and
mic-rename tasks, and takes over an older LibrePods or zip install (your settings
and heart-rate history are kept). Restart when it asks. Uninstall from
**Settings ▸ Apps**; that also removes the drivers, the tasks and the test
certificate. If something fails, the log is in `%ProgramData%\NTPods\setup.log`.

To build the MSI yourself: [`installer/msi/build-msi.ps1`](installer/msi/build-msi.ps1)
(WiX 5) on a folder made by [`installer/make-dist.ps1`](installer/make-dist.ps1).

### b2) Install from the zip
**`NTPods-Windows.zip`** on the same release has the same files. Extract it and
run [`installer/install.ps1`](installer/install.ps1) from an **admin** PowerShell
inside the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

It checks Test Mode is on, test-signs and installs **both** drivers, copies
`ntpodsd.exe` + `ntpods-winui.exe` (and the FFmpeg DLLs) to
`%LOCALAPPDATA%\NTPods`, registers the driver-recovery and mic-rename tasks,
and adds the app to startup. The folder is self-contained: no Windows SDK/WDK,
Visual Studio or VC++ redistributable needed. Reboot afterwards.

### c) Install — just the drivers
The release zip carries both driver packages, built from source by CI:
`driver\` (AAP channel) and `driver-mic\` (virtual mic), each `.inf` + `.sys` +
`.cat`. To install or update only the drivers, point the repo's scripts at those
folders from an **admin** PowerShell. The same packages are committed under
`drivers/*/prebuilt`, but those are refreshed by hand and **can lag the source** —
prefer the release zip.

```powershell
.\drivers\aap\install.ps1 -PackageDir <zip>\driver   # AAP channel  (or .\drivers\aap\prebuilt)
.\drivers\mic\install.ps1 -Dir <zip>\driver-mic      # virtual mic  (or .\drivers\mic\prebuilt)
```

Success for the AAP driver shows `Driver package installed on device:
BTHENUM\{74ec2172-...}`. Check it loaded (should be `OK`, not error 52):
```powershell
Get-PnpDevice -FriendlyName "NTPods AAP*" | Select Status
```
The mic driver creates a `ROOT\AudioCodec` device via `devcon`; a virtual
microphone should appear in **Sound ▸ Input**.

### Building the drivers yourself (optional)
CI builds both drivers on every run ([`ci-windows.yml`](../.github/workflows/ci-windows.yml):
`windows-2022`, SDK + WDK 10.0.26100 via winget, catalogs regenerated with Inf2Cat).
To build locally you need Visual Studio 2022/2026 with **Desktop development with
C++** + **Spectre x64/x86 libs** + a **Windows 11 SDK** and the **matching WDK**
(SDK & WDK build numbers must match, e.g. `28000`). See
[`drivers/aap/README.md`](drivers/aap/README.md) and
[`drivers/mic/README.md`](drivers/mic/README.md).

### Uninstall / revert
```powershell
pnputil /delete-driver oem<N>.inf /uninstall   # find <N> with: pnputil /enum-drivers
bcdedit /set testsigning off                    # then re-enable Secure Boot in BIOS
```
The app's data (settings, logs, the heart-rate history) lives in
`%LOCALAPPDATA%\NTPods` — delete that folder to remove it too.

---

## 2. Run the app

Two pieces run: the **daemon** (`ntpodsd.exe`, headless) and the **WinUI app**
(`ntpods-winui.exe`). Build the daemon natively on Windows, or from WSL/Linux
(cross-compiled): `cargo build --release --target x86_64-pc-windows-gnu` in
`daemon/` — run `daemon/fetch-ffmpeg.sh` first, the FFmpeg slice used for AAC-ELD
decoding is fetched, not committed. Build the WinUI app with Visual Studio's
MSBuild (`dotnet build` can't load the WinUI PRI task). The release zip bundles
both, the FFmpeg DLLs and the two drivers CI built from source.

Launch `ntpods-winui.exe`; it auto-starts the daemon, shows a tray icon, and its
window hides to the tray on close. To start it at login, use the installer (which
registers it) or [`startup.ps1`](startup.ps1).

### How it works
- The daemon finds your paired AirPods, opens the driver, and holds an **AAP
  session** (connect → handshake → request notifications), keeping battery, noise
  mode and the rest up to date, and serving the app over IPC.
- It watches passively for the AirPods' **BLE proximity advertisement** while
  disconnected and connects when they show up, so the session comes back on its
  own after they leave and return.
- **Left-click / right-click the WinUI tray icon** for the menu:
  - the device name + **Left / Right / Case** battery,
  - **Noise Control**: Off · Noise Cancellation · Transparency · Adaptive
    (the current one is checked; click to switch — sends the AAP command),
  - **Mute**, **Open** (the main window), **Quit**.
- The main window adds volume, ear detection, conversational awareness, adaptive
  volume, the hi-res mic, heart rate, hearing aid and device rename.
- Hover the icon for a tooltip with battery + current mode.
- If the link drops it reconnects automatically.

### The hi-res microphone
The daemon watches the virtual mic's capture-activity counter: when any app opens
"NTPods" as its microphone, it enables the AAP uplink automatically, decodes the
AAC-ELD stream and feeds the driver; when the app releases the mic it stops
(debounced) and restores A2DP stereo. There's a manual toggle too. While the mic is
active the AirPods are in their bidirectional call mode, so playback is mono — that
is the AirPods' behaviour, not a bug; stereo is restored when the mic stops.

### Heart rate (AirPods Pro 3)
Switch **Monitor heart rate** on in the Heart Rate card. After a few seconds while
the sensor settles you get one reading per second:

- the **current BPM**, and a graph of the **last minute** with its min / avg / max
  (hover the graph for a reading's value and how long ago it was);
- the **Readings** picker switches the graph to a **past session**: every reading
  of it, with its stats and the time of each point.

Every reading is kept in a dedicated SQLite database,
`%LOCALAPPDATA%\NTPods\heart-rate.sqlite3` (`sessions` + `samples`: time, BPM
and the sensor's confidence), so you can also query it with any SQLite tool. It
uses extra battery while it's on.

The PC has to be the AirPods' **active** device — if your iPhone is holding them,
they don't answer sensor requests from the PC. How it works (and why it needed the
driver's 1691-byte L2CAP MTU): [`docs/heart-rate.md`](docs/heart-rate.md).

### Bonus
Keeping the AAP session alive (app running) tends to **stabilize the audio** —
the AirPods stop bouncing between the HFP (mono, "static") and A2DP (stereo)
profiles, because a proper AAP host is talking to them.

### Notes / limits
- The AAP channel is **exclusive** — the daemon owns it, which is why the UIs are
  IPC clients rather than talking to the driver themselves. Several UI clients can
  run at once.
- **Heart rate** — AirPods Pro 3 only (the model it's been verified on); see
  [Heart rate](#heart-rate-airpods-pro-3) above.
- **Hearing aid** is still experimental — it's behind **Settings ▸ Experimental**.
- Requires both drivers installed and Test Mode on.
