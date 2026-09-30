# Prebuilt NTPodsAAP driver package

The compiled driver (`NTPodsAAP.sys` + `.inf` + `.cat`) so you can install
**without building it** — no Visual Studio / C++ / WDK required.

Install (admin PowerShell, Test Mode — see [the Windows README](../../../README.md)):
```powershell
& "..\install.ps1" -PackageDir ".\"
```
`install.ps1` creates a test certificate, signs these files, trusts the cert and
installs the driver. Then run `ntpods-winui.exe`, which starts the daemon
(`ntpodsd.exe`) itself.

Neither the daemon (Rust) nor the WinUI app (C#) needs a C++ toolchain either.
