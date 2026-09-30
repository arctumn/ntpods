# Heart rate on Windows

**Short version: heart rate works on Windows.** AirPods Pro 3 stream heart rate at
1 Hz into the app. The fix was not in the AAP protocol at all. It was the **L2CAP
MTU of the AAP channel**, which is set by the driver. This page records the cause,
what the daemon sends and decodes, and what was ruled out on the way, so nobody has
to repeat it.

Verified on AirPods Pro 3 (A3063/A3064) with iOS 27 firmware, Windows 11 and an
Intel AX210, 2026-09-29.

---

## The cause: the AAP channel's MTU

For months the AirPods *accepted* every heart-rate request and never sent a
reading. Two things were behind it.

- **The driver opened the AAP channel (PSM `0x1001`) without an MTU option.**
  `bthport` then sent a Configure Request with no MTU, and the inbound MTU stayed
  at the **672-byte** L2CAP default.
- **The AirPods only publish the RTBuddy sensor services whose descriptor fits in
  that MTU.**

| RTBuddy service | descriptor size | fits in 672? |
|---|---|---|
| 16 `devmotion6` | ~521 B | ✅ |
| 14 `activity` (+ 18) | ~573 B | ✅ |
| 19 `HEARTRATE` / 20 `HEARTRATEv2` | **~920 B** | ❌ |

With 672, the heart-rate services were never advertised to this host, and the
symptoms followed from that:

- service 19 answered `kIOReturnBadArgument` (`0xE00002C2`);
- a start on 84 was ACKed (as 20) but never streamed;
- no BPM ever arrived.

Android's stack (Fluoride) requests **MTU 1691**, and so does Bumble. That is why
heart rate worked there. The macOS user-space probe hit the same 672-byte ceiling
we did.

The fix is in [`drivers/aap/L2cap.c`](../drivers/aap/L2cap.c):

```c
brb->ConfigIn.Flags         = CFG_MTU;
brb->ConfigIn.Mtu.Min       = 672;
brb->ConfigIn.Mtu.Preferred = 1691;
brb->ConfigIn.Mtu.Max       = 1691;
```

**On `bthport`, `ConfigIn` is the inbound direction.** It becomes the MTU option of
*our* Configure Request. `ConfigOut` only caps what we send. Setting it there shows
up in our Configure *Response* and changes nothing. Both were confirmed on the air
with an HCI ETW capture.

The channel is also opened `CF_LINK_AUTHENTICATED | CF_LINK_ENCRYPTED`, like the
socket upstream android/rewrite opens. Heart rate was verified in that
configuration. Whether it strictly needs those flags, or only the MTU, is not yet
isolated. On Linux, an unencrypted AAP socket is known to suppress the AAP
notification stream (from LibrePods, librepods-org/librepods#617).

## What the daemon sends

This runs when heart rate is switched on (`hr_retry_campaign` in
[`daemon/src/main.rs`](../daemon/src/main.rs)):

| Step | Frame |
|------|-------|
| connect / capabilities, services 0 and 4 | `00 00 00 00 01 00 03 …`, `04 00 00 00 01 00 00`, … |
| `HRM_STATE` (0x30) enable | `04 00 04 00 09 00 30 01 00 00 00` |
| start, service **84** (`HEARTRATE_COMMAND`) | `… 42 0b 08 54 10 02 1a 05 01 40 42 0f 00` (1 s interval) |
| start, service 19 (older firmware) | same, `08 13`. It NAKs `BadArgument` on iOS 27 firmware, which is harmless. |

On iOS 27 firmware the AirPods answer the start on 84 as **service 20**
(HEARTRATEv2), and the readings arrive there. The first locked sample lands about
6–8 s after the start.

## What the daemon decodes

Each reading is an 18-byte payload inside a RTBuddy SensorDataWX frame
([`daemon/src/hr.rs`](../daemon/src/hr.rs)):

| byte | meaning |
|---|---|
| 1 | **BPM** |
| 2 | **confidence**: ~20 during PPG warm-up, 160–240 once locked |
| 3 | per-sample counter |
| 15–17 | status tail: `10 00 00` (also `10 00 80`, `20 00 00`, `20 80 00`, `20 02 80`, `20 82 80`) |

A reading counts only if the BPM is within 30–220, the tail is known, **and
confidence is ≥ 0x80**. Warm-up readings can be far off while still inside 30–220,
so the confidence gate is what keeps them out.

## Things that were ruled out

These were all tested before the MTU was found. None of them unblocked heart rate
at 672 bytes.

- **The AAP sequence and timing.** We went byte for byte with PR #702 and with
  upstream android/rewrite: its connect burst (`03` handshake, features `d7`,
  country code, magic-keys request), seq encoding, and with and without
  `HRM_STATE` or the service-0 init.
- **Service ids and config layout.** A scan of RTBuddy services 1–63 was done: the
  id behaves as 6 bits, so 84 is answered as 20. Several HID report ids and sizes
  on service 19 were also tried.
- **Waking RTBuddy with motion first**, and running a real walk with the activity
  classifier moving.
- **Host identity.** We tried three Device-ID records (vendor-only Apple spoof, an
  AirPod's own record, an iPhone's exact record), Class of Device (laptop and
  phone), and a fresh pairing.
- **L2CAP ERTM.** `bthport` does not send it, and the AirPods run AAP in Basic mode
  on every host anyway.
- **Link security alone.** An authenticated + encrypted channel with MTU 672 still
  gave nothing.

What finally isolated it was driving the same AX210 with **Bumble** (WinUSB) at
MTU 1691. Right after the AACP connect, the buds pushed the HR descriptors on
their own and streamed BPM. Comparing descriptor sizes against the 672-byte MTU
seen in older btvs captures pointed at the channel configuration.

Two protocol notes from the investigation:

- **Service 14 (`0x0E`) is the activity classifier, not head tracking.** It sends a
  23-byte record at ~5 Hz, and its byte 12 is the activity state: 3 = still, 0/1/2
  while moving. Head tracking is `devmotion6` (16). Heart rate does not need
  either one stopped.
- **The AirPods only answer sensor requests from the active host.** With another
  device (e.g. the iPhone) holding the buds, RTBuddy stays silent to the PC.

## In the app

The **Heart Rate** card is always on the device page. It is no longer behind
Settings ▸ Experimental. Switching **Monitor heart rate** on starts the stream.

- The card shows the current BPM and a graph of the last minute, with min / avg /
  max. Hovering a point shows its value.
- The **Readings** picker switches the graph to a past session.

Every reading is stored by the daemon (`daemon/src/hrdb.rs`) in
`%LOCALAPPDATA%\NTPods\heart-rate.sqlite3`, which has two tables:

- `sessions` (device, start, end);
- `samples` (session, Unix ms, BPM, confidence).

The app only reads it. HR has only been verified on AirPods Pro 3, and it uses
extra battery while it's on.

## References

- [`drivers/aap/L2cap.c`](../drivers/aap/L2cap.c) sets the channel's MTU and
  security flags.
- [`daemon/src/main.rs`](../daemon/src/main.rs) holds `hr_retry_campaign`, the
  enable and start sequence.
- [`daemon/src/hr.rs`](../daemon/src/hr.rs) holds the RTBuddy decoder and the
  validity rules.
- Upstream PR #702 is the Android heart-rate implementation. Our write-up of the MTU
  finding is in its thread.
