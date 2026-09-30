# Prebuilt NTPodsMic driver package

The compiled virtual-microphone driver (`NTPodsMicPC.sys` + `.inf` + `.cat`) so you
can install it **without building it** — no Visual Studio / C++ / WDK required.

`ntpodsmicpc.cat` was generated from exactly these two files with
`inf2cat /driver:. /os:10_X64`. **Rebuilding the driver or editing the INF means
regenerating the catalog** (WDK machine), otherwise the package won't install.
CI rebuilds all three on every run, so the release zip is always current; these
committed copies are refreshed by hand and can lag the source.

To install, run the release folder's `install.ps1` from an **admin** PowerShell —
it test-signs the `.sys` + `.cat` with a local cert and uses `devcon` to (re)create
the `ROOT\NTPodsMicPC` device, so a virtual microphone appears in Sound > Input.
