# NTPods

Open-source AirPods control for the PC: battery, noise control, ear detection,
conversational awareness, the AirPods' **hi-res microphone as a real input**,
**heart-rate monitoring** (AirPods Pro 3), hearing aid and more — free, with the
kernel drivers included.

> [!NOTE]
> **Transition in progress.** NTPods started as the Windows port of
> [LibrePods](https://github.com/kavishdevar/librepods) (developed in the
> [arctumn/librepods](https://github.com/arctumn/librepods) fork). At the LibrePods
> maintainer's request it continues as its own project, under its own name. Until
> the rename lands, the code, the app and the release still say "LibrePods" in
> places — that is expected. Please report NTPods issues **here**, not to LibrePods.

## Platforms

| Platform | Status | Where |
|---|---|---|
| **Windows 10 / 11** | ✅ native WinUI 3 app + daemon + two kernel drivers | [`windows/`](windows/README.md) |
| WSL / Linux | planned — the layout leaves room for it next to `windows/` | — |

For Android and Linux today, use [LibrePods](https://github.com/kavishdevar/librepods).

## How it compares

A fair-as-we-can snapshot (Sept 2026), from each project's own README, store page and docs — corrections welcome.
✓ yes · ◐ partial / experimental · — no.

| | **NTPods** | [LibrePods](https://github.com/kavishdevar/librepods) | [MagicPods](https://magicpods.app/) |
|---|---|---|---|
| Platforms | Windows (WSL/Linux planned) | Android, Linux | Windows, Steam Deck (Linux) |
| Price / license | **Free, GPL-3.0 — app and both kernel drivers** | Free, GPL-3.0 | Paid on the Microsoft Store; app source open, AAP driver separate |
| Battery (L / R / case) | ✓ | ✓ | ✓ |
| Noise control (Off / ANC / Transparency / Adaptive) | ✓ | ✓ | ✓ |
| Ear detection auto-pause | ✓ | ✓ | ✓ |
| Conversational Awareness | ✓ | ✓ | ✓ |
| Adaptive noise strength, Allow-Off, Adaptive / Personalized Volume | ✓ | ✓ (Android) | ◐ |
| **Hi-res AirPods microphone** as a system input | ✓ (own virtual mic driver) | — | — (system HFP, 16 kHz) |
| **Heart rate** (AirPods Pro 3) | ✓ live BPM, graph, session history | ◐ in development (PR #702) | — |
| Hearing-aid audiogram | ◐ experimental | ◐ Android (needs VendorID spoofing) | — |
| Head gestures | — | ✓ (Android) | — |
| Other earbuds (Galaxy Buds, Beats, Nothing…) | — | ◐ (Linux: Nothing) | ✓ |
| Low-latency gaming mode | — | — | ✓ |
| Needs Windows Test Mode | yes (test-signed drivers) | n/a | Store build: no; open build: yes |

Where the others are ahead is stated plainly: MagicPods has multi-vendor support, a
low-latency mode and a signed build that runs without Test Mode; LibrePods covers
Android and Linux and has head gestures. NTPods' edge on Windows: fully free and
open — drivers included — with the hi-res mic and heart rate.

## Get it (Windows)

Download `LibrePods-Windows.zip` from the latest release, extract it and run
`install.ps1` from an **admin** PowerShell. The drivers are test-signed, so Windows
must be in **Test Mode** (Secure Boot off) — read the
[Windows README](windows/README.md) first; it covers the risks, install, uninstall
and every feature.

## Repository layout

- [`windows/`](windows) — everything Windows: the AAP L2CAP and virtual-mic
  drivers, the `librepodsd` daemon (Rust), the WinUI 3 app (C#), the installer.
- [`docs/`](docs), [`AAP Definitions.md`](AAP%20Definitions.md) — the AirPods
  protocol notes, shared by every platform.
- [`.github/workflows/ci-windows.yml`](.github/workflows/ci-windows.yml) — builds
  both drivers, the daemon and the app from source and publishes the release zip.

## Credits

- **[LibrePods](https://github.com/kavishdevar/librepods)** by
  [kavishdevar](https://github.com/kavishdevar) and contributors — the reverse-
  engineered AirPods protocol this project is built on, and where it started.
  NTPods is not affiliated with LibrePods.
- Heart rate: [@thibaup](https://github.com/thibaup)'s Android implementation
  (LibrePods PR #702) and [@SAGIRIxr](https://github.com/SAGIRIxr)'s findings.
- Driver builds in CI: the WDK-via-winget approach from
  [@Gab4545](https://github.com/Gab4545)'s fork.
- Protocol dissectors: [pabloaul/apple-wireshark](https://github.com/pabloaul/apple-wireshark).

## License

[GPL-3.0](LICENSE), like LibrePods. AirPods is a trademark of Apple Inc.; NTPods
is not affiliated with or endorsed by Apple.
