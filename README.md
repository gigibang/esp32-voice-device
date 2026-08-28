# ESP32-S3 Voice Device — research notes and protocol work

Engineering notes from building a self-hosted AI voice device on the ESP32-S3: hardware selection,
stock-firmware reverse engineering, the wire protocol, and the backend architecture that replaces the
vendor cloud.

**The headline finding:** the stock firmware on these commercial xiaozhi-protocol voice toys already
ships a user-editable **Custom OTA URL** field in its captive portal. Because the OTA response is what
hands the device its WebSocket URL and token, whoever controls that URL controls the device's entire
conversation backend — which means self-hosting needs **no custom firmware, no re-flashing, and no DNS
interception**. The field and its persistence path are confirmed on hardware and in the firmware
source; the end-to-end repoint onto a self-hosted server has not been exercised yet. Details in
[captive-portal-ota-finding.md](docs/captive-portal-ota-finding.md).

---

## Contents

| Document | What it covers |
|---|---|
| [captive-portal-ota-finding.md](docs/captive-portal-ota-finding.md) | The OTA-redirect finding: how the stock captive portal exposes a backend override, and what that means for self-hosting |
| [protocol.md](docs/protocol.md) | The xiaozhi wire protocol from a server implementer's point of view — OTA handshake, WebSocket framing, Opus audio, control messages |
| [stock-behavior.md](docs/stock-behavior.md) | Stock firmware state machine as observed on real hardware: boot, activation, NVS persistence, idle behaviour |
| [server-architecture.md](docs/server-architecture.md) | Backend design — transport / core / provider layering for one conversation across several device types |
| [wm8960-audio-fix.md](docs/wm8960-audio-fix.md) | A silent-speaker bug on the WM8960 codec, its root cause in the device-tree regulator declaration, and the register-level fix |
| [board-selection.md](docs/board-selection.md) | Hardware selection study across 12 ESP32-S3 dev boards — audio subsystem, power management, form factor (**written in Chinese**) |

`tools/` holds the shell scripts used for the hardware work: flash dump and restore over `esptool`,
and packet capture and analysis over `tshark`.

### board-selection.md — English summary

The Chinese document compares 12 Waveshare ESP32-S3 boards for suitability as a voice device, and its
conclusions are:

- The differentiator is not the display — it is the **audio subsystem**. Boards split into those with a
  dual-microphone array plus a dedicated **ES7210** mic-array ADC, and those with a single mic and no
  echo reference at all. The ES7210 does not itself cancel echo — it supplies the reference channel
  that the AEC stage (running in ESP-SR on the S3) needs. Without it, speaker output feeds back into
  the mic and the device either has to run quiet or talks over itself.
- Second differentiator: **power management**. An `AXP2101` PMIC gives accurate coulomb-counted charge
  state and low deep-sleep current; the cheap single-chip chargers do not.
- Vendor product tables mark features as a binary "present / absent", which hides that an on-board
  speaker and a speaker *connector* are both ticked the same way. The on-board resource decal
  photographed on the PCB turned out to be more reliable than the marketing page.
- A silicon revision trap: one board silently changed MCU between hardware revisions (4MB flash / 2MB
  PSRAM → 8MB / 8MB). Only the vendor wiki documents this; the shop listing does not. The smaller part
  cannot hold the firmware.

---

## Project Highlights for SAEF Application

Concrete embedded / IoT work demonstrated by the material in this repository:

**Embedded systems and hardware bring-up.** Component-level selection across a dozen candidate boards,
reasoning about audio codecs (ES8311), mic-array ADCs that feed echo cancellation (ES7210), Class-D amplifiers
(NS4150B), IMUs, and power-management ICs — and the trade-offs between them for a battery-powered
device. Flash dump and restore over `esptool`, and reading a board's on-PCB resource decal as
primary-source documentation when vendor product tables proved unreliable.

**Low-level debugging.** The [WM8960 fix](docs/wm8960-audio-fix.md) is representative: a silent speaker
with no error logged anywhere, traced to a device-tree overlay that declares no `SPKVDD` regulator,
which causes the kernel driver to skip the speaker-enable bits in the codec's PWR2 register. The fix is
a direct I²C register write with a non-obvious 7-bit-address-plus-9-bit-data encoding, and an ordering
constraint against the ALSA regmap sync. This is the class of problem where the datasheet, the kernel
driver, and the observed behaviour all have to be read against each other.

**Protocol reverse engineering.** [protocol.md](docs/protocol.md) is a server-side specification of a
binary-plus-JSON WebSocket protocol — OTA handshake, authentication headers, Opus frame framing, and
control-message state machine — derived by reading the upstream firmware source. The OTA leg has been
observed on real hardware; the WebSocket voice leg is specified from source and has not yet been
exercised end-to-end. Each document marks which of its claims are observed and which are inferred.

**Systems architecture.** [server-architecture.md](docs/server-architecture.md) documents a backend
layered so that a new client type is one new file: transports isolate wire formats, core owns
conversation state, providers wrap swappable vendor APIs behind fallback chains. Stateless HMAC device
tokens were chosen specifically because an embedded client cannot carry session state across power
cycles.

**Security-conscious engineering.** On the unit examined here, the NVS partition still held the
vendor's factory-test Wi-Fi credentials as shipped, and the same partition stores end-user Wi-Fi
credentials in cleartext. That shapes what this repository contains: analysis and procedures are
published; **flash images are not**, because they are credential-bearing and are someone else's
firmware build, not mine to redistribute.

**Working in the open, carefully.** Everything here has been reviewed for credentials, device
identifiers, network names, and location-identifying data before publication. Placeholders such as
`<home-ssid>` and `aa:bb:cc:dd:ee:ff` are deliberate.

---

## Scope of this repository

This is a **documentation repository**. It contains research notes, a protocol specification, an
architecture write-up, and the shell tooling used during hardware work.

Deliberately not included:

- **Firmware images** dumped from devices I own. They carry cleartext Wi-Fi and broker credentials,
  and they are a vendor's own firmware build that is not mine to redistribute. `tools/dump_flash.sh`
  lets anyone produce their own from their own hardware.
- **Application source** for the backend and the mobile client, which live in private repositories.
- Personal network details, device identifiers, and location-identifying scan data, all replaced with
  placeholders.

## Credits

The devices studied here run [78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) (MIT), an
open-source ESP32 voice-assistant firmware. The protocol documented in
[protocol.md](docs/protocol.md) is that project's, read from its published source; this repository adds
a server implementer's view of it and the hardware research around it. Upstream's MIT notice is
reproduced in [THIRD-PARTY.md](THIRD-PARTY.md).

The WM8960 note comes from a Raspberry Pi prototype that preceded the ESP32-S3 work — same voice
device, earlier hardware.

## License

MIT — see [LICENSE](LICENSE). Third-party notices: [THIRD-PARTY.md](THIRD-PARTY.md).
