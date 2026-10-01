# NTPodsMic — virtual audio (microphone) driver (ACX)

> One of the two mic drivers NTPods ships. This ACX one is the default on Windows
> 11 22H2 or newer, the only Windows it loads on. Older Windows (10 2004+) gets the
> PortCls one in [`../mic-portcls`](../mic-portcls), which has the same
> `\\.\NTPodsMic` control device; it can be picked on Windows 11 too (MSI option,
> or `install.ps1 -MicDriver portcls`). The installer removes whichever one isn't
> chosen.

The virtual-microphone driver for the [hi-res mic feature](../../docs/hires-mic/PLAN.md):
Windows sees a **NTPods** microphone that the daemon feeds with the AirPods'
decoded AAC-ELD audio, so any app (Teams, Zoom, Discord, OBS…) can use it.

## Origin / license

This is based on the **Microsoft ACX `AudioCodec` sample** from
[microsoft/Windows-driver-samples](https://github.com/microsoft/Windows-driver-samples/tree/main/audio/Acx/Samples)
(**MIT licensed**), chosen because:

- it's a **ROOT-enumerated** (software, no-hardware) audio device — i.e. virtual;
- it already has a **capture circuit** (`Common/CaptureCircuit.cpp`) — a mic;
- it uses **ACX** on top of **KMDF** — the same framework family as our
  `NTPodsAAP` driver (unlike SYSVAD's older PortCls).

It was trimmed to capture-only (the render circuit is gone, so no phantom speaker
grabs the default output) and its audio source swapped for a PCM feed pushed from
user mode over an IOCTL.

## Status

Done and in daily use:

- [x] **Builds** with VS2026 + WDK 28000 (ACX headers present) — `AudioCodec.sys`.
- [x] **Installs + a virtual mic appears** — `install.ps1` (elevated, Test Mode)
  signs + catalogs the driver and creates the `ROOT\AudioCodec` device via
  devcon. A **NTPods** microphone shows up in Sound ▸ Input.
- [x] **Capture-only** — the render (speaker) circuit was removed from `Device.cpp`.
- [x] **PCM bridge** — `Common/MicPipe.{h,cpp}`: a spin-locked ring buffer and a
  control device `\\.\NTPodsMic` with `IOCTL_NTPODS_MIC_WRITE_PCM`
  (`0x0022A000`). `StreamEngine::ProcessPacket` drains the ring instead of the
  sample's WAV/tone dummy; an underrun reads as silence.
- [x] **Bounded latency** — the uplink and the capture timer run on independent
  clocks, so the ring used to creep up to full and stay there, adding its whole
  capacity (~1.36 s) as a fixed delay. It now trims back to ~100 ms whenever the
  backlog passes ~160 ms (never below two capture packets), so mic latency stays
  put instead of drifting. 100 ms covers the uplink's jitter: the AirPods send
  30 ms per packet, but gaps of up to ~100 ms between packets are normal, and a
  32 ms target crackled on every late one. Thanks to [@Gab4545](https://github.com/Gab4545) for
  diagnosing it.
- [x] **Capture-activity counter** — `IOCTL_NTPODS_MIC_STATUS` advances while an
  app records, which is how the daemon auto-starts and auto-stops the AAP uplink.
- [x] The capture circuit is restricted to **48 kHz mono 16-bit** (what the decoded
  AirPods stream is resampled to).

A **prebuilt, ready-to-install package** is committed in [`prebuilt/`](prebuilt) —
no Visual Studio or WDK needed to install it.

## Build

On the Windows host (VS + WDK), build `AudioCodec/Driver/AudioCodec.sln` (or
`msbuild AudioCodec/Driver/AudioCodec.vcxproj /p:Configuration=Release /p:Platform=x64`)
→ `AudioCodec/Driver/x64/Release/AudioCodec.sys`, which `install.ps1` picks up by
default. See [`../../docs/hires-mic/PLAN.md`](../../docs/hires-mic/PLAN.md) for the
design and the protocol notes.
