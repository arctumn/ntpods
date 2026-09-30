# NTPods

Control your AirPods from a Windows PC: battery, noise control, ear detection,
conversational awareness, the hi-res microphone as a normal input, heart rate on
AirPods Pro 3, and a few more things. It's free and open source, drivers included.

> [!NOTE]
> NTPods started as the Windows port of [LibrePods](https://github.com/kavishdevar/librepods),
> in my fork [arctumn/librepods](https://github.com/arctumn/librepods). The LibrePods
> maintainer asked me to give it its own name, so it lives here now. Some parts
> of the code and the release still say "LibrePods" until I finish renaming.
> Please open issues here, not on LibrePods.

## Platforms

Right now it's Windows 10/11 only (everything is in [`windows/`](windows/README.md)).
I'd like to add WSL/Linux later, which is why the Windows code sits in its own folder.

On Android or Linux, use [LibrePods](https://github.com/kavishdevar/librepods).

## Compared to LibrePods and MagicPods

Based on each project's README and store page as of September 2026. If something
here is wrong, open an issue and I'll fix it.

| | NTPods | [LibrePods](https://github.com/kavishdevar/librepods) | [MagicPods](https://magicpods.app/) |
|---|---|---|---|
| Platforms | Windows | Android, Linux | Windows, Steam Deck |
| Price | Free (GPL-3.0, drivers too) | Free (GPL-3.0) | Paid (Microsoft Store) |
| Battery | yes | yes | yes |
| Noise control | yes | yes | yes, with its driver |
| Ear detection | yes | yes | yes |
| Conversational awareness | yes | yes | yes, with its driver |
| Adaptive / personalized volume, allow off | yes | Android | partial |
| Hi-res mic as a system input | yes | no | no |
| Heart rate (AirPods Pro 3) | yes | Android | no |
| Hearing aid | experimental | Android, needs VendorID spoofing | no |
| Head gestures | no | Android | no |
| Other earbuds | no | Nothing (Linux) | yes |
| Low-latency mode | no | no | yes |
| Needs Test Mode on Windows | yes | n/a | yes, for its driver (ANC and most AirPods features) |

Like NTPods, MagicPods needs a driver for noise control and most AirPods features,
and that driver needs Test Mode (a community-signed build only works on Windows
versions before the April 2026 update). MagicPods is the better pick if you use
non-Apple earbuds or want a low-latency mode. LibrePods is what you want on Android
and Linux.

## Installing on Windows

Download `LibrePods-Windows.zip` from the latest release, extract it and run
`install.ps1` in an admin PowerShell. The drivers are only test-signed, so Windows
has to be in Test Mode with Secure Boot turned off. Read the
[Windows README](windows/README.md) before you do this; it explains the risks and
how to undo it.

## What's in the repo

- `windows/`: the two drivers (AAP channel and virtual mic), the daemon (Rust), the
  WinUI app (C#) and the installer
- `docs/` and `AAP Definitions.md`: notes on the AirPods protocol
- `.github/workflows/ci-windows.yml`: builds everything and publishes the release

## Credits

- [LibrePods](https://github.com/kavishdevar/librepods) by
  [kavishdevar](https://github.com/kavishdevar) and its contributors. The protocol
  work this is built on comes from there. NTPods isn't affiliated with LibrePods.
- [@thibaup](https://github.com/thibaup) (heart rate on Android, LibrePods PR #702)
  and [@SAGIRIxr](https://github.com/SAGIRIxr) for their heart-rate findings.
- [@Gab4545](https://github.com/Gab4545) for building the drivers in CI.
- [pabloaul/apple-wireshark](https://github.com/pabloaul/apple-wireshark) for the
  Wireshark dissectors.

## License

GPL-3.0, same as LibrePods. AirPods is a trademark of Apple Inc. This project isn't
affiliated with Apple.
