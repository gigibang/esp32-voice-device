# Finding — Stock firmware ready-state behavior (Device 2, already activated)

**Date**: 2026-05-21
**Device state at observation**: already activated to user's xiaozhi.me account in a prior session (sometime before 2026-05-21), wifi credentials for `<home-ssid>` already in NVS.

## Procedure that got us here

1. Device was in `kDeviceStateStarting` → boot button single-press → entered `EnterWifiConfigMode()` → SoftAP `Xiaozhi-XXXX` (see [captive-portal-ota-finding.md](captive-portal-ota-finding.md))
2. Phone connected to SoftAP → `http://192.168.4.1` → Wi-Fi Config tab → tapped `<home-ssid>` from scan list → entered home wifi password → **Connect**
3. Device rebooted, associated with home wifi
4. Device made `POST` to `api.tenclass.net/xiaozhi/ota/` (Custom OTA URL field is empty, so it used the compiled-in fallback `CONFIG_OTA_URL`)
5. tenclass.net recognized the device's client UUID (redacted here) as already-activated → response had no `activation` section (only `websocket` + maybe `server_time`)
6. Device skipped `kDeviceStateActivating` → went straight to `kDeviceStateIdle`

## What the LCD shows in idle / ready state

User-reported observation:
- **Eyes** — the xiaozhi character face (two eyes), animated (blinking)
- **Time** — wall-clock time digits (sourced from `server_time` in the OTA response, set via `settimeofday()` in `ota.cc`)
- **WiFi signal indicator** — confirms successful association with `<home-ssid>`
- **Battery indicator** — bar/percentage showing current charge state (Spotpear muma has battery + ADC1 ch0 battery voltage sense per the board's hardware notes)

What's *not* visible at this state:
- No activation code (because already activated)
- No "connecting" / "loading" spinner (already past starting state)
- No status text about the backend (just trusts tenclass)

## What this confirms about our protocol understanding

- The OTA endpoint round-trip succeeded silently → no UI feedback for "OTA succeeded", device just transitions states
- `server_time` is being respected — without it the LCD clock would show 1970 or boot time
- The device's NVS persistence works as expected: wifi creds + activation token survive reboots, no re-pairing needed
- TLS to `api.tenclass.net` works out of the box with system CA bundle (no cert pinning concerns for our self-host either)

## Open observations (not exercised this session)

If the user says "小智" (wake word) or presses the touch screen, the device should:
1. Transition `Idle → Connecting` (open WS to `wss://api.tenclass.net/xiaozhi/v1/`)
2. Send the hello frame (per [protocol.md §2.2](protocol.md))
3. After server hello → `Connecting → Listening` → stream user's voice as Opus binary frames
4. Server returns `stt` (subtitle), then `tts:start` + binary Opus playback + `tts:stop`
5. `Speaking → Idle` (or loop to Listening if auto-mode)

Worth a quick test next session to confirm the wake word works on this hardware and to baseline TTS quality. Don't need pcap — just observe LCD subtitle + audio playback.

## NVS divergence note (relevant for restore planning)

Current NVS state contains:
- Saved wifi: two entries — the home network and the vendor's factory-test SSID (see [captive-portal-ota-finding.md](captive-portal-ota-finding.md))
- An activation token bound to a xiaozhi.me account, written after the flash dump was taken

The stock flash dump was taken **before** account activation, which has two consequences worth planning around:
- Restoring that image rolls the device back to a pre-activation state, and it will need re-activating via xiaozhi.me to restore voice chat.
- For a backup that captures current user state, re-run the dump procedure (`esptool read-flash 0 0x1000000 ...`) into a fresh directory. Worth doing before any destructive experiment.

> Flash images are credential-bearing — the NVS partition holds Wi-Fi and broker credentials in cleartext. Keep dumps local; only the derived analysis belongs in a public repo.

## Implication for self-hosting

Already-activated state is **not a blocker** for self-hosting:
- The activation token in NVS is only used when contacting `api.tenclass.net`
- Once we set Custom OTA URL = our backend, the device stops calling tenclass entirely → activation token becomes dormant data
- We don't need to unbind from xiaozhi.me to repoint the device

Next step from here: design and scaffold a self-hosted OTA + WebSocket server. The alternatives — building a custom firmware, or intercepting DNS for `api.tenclass.net` on the LAN — are both unnecessary given the Custom OTA URL field.
