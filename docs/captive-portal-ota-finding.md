# Finding — Captive portal exposes Custom OTA URL field

**Date observed**: 2026-05-21
**Device**: Spotpear sp-esp32-s3-1.54-muma (ESP32-S3, 16MB flash / 8MB PSRAM)
**Stock firmware**: as-shipped, analysed from a local flash dump (the image itself is not redistributed — see the note in the repo README)
**How we got here**: physical reset (USB unplug/replug) → boot button single-press during the `kDeviceStateStarting` window → device enters `EnterWifiConfigMode()`

## TL;DR

The stock firmware's captive portal at `http://192.168.4.1` has a **Custom OTA URL** field in its Advanced tab. That field is empty by default and user-editable. Setting it overrides the firmware's compiled-in default (`https://api.tenclass.net/xiaozhi/ota/`).

**Implication**: the "no-flash self-hosting" path is viable. The override field exists, is user-editable, and persists to NVS where `ota.cc` reads it — so the device can be pointed at a self-hosted backend without modifying or re-flashing firmware. *Observed*: the field, its defaults, and the NVS key it writes. *Not yet exercised*: an end-to-end repoint onto a self-hosted OTA endpoint.

## SoftAP details

- **SSID broadcast by device**: `Xiaozhi-XXXX`, where `XXXX` is the last two octets of the SoftAP MAC in hex
- **How that suffix is derived**: ESP-IDF's default is SoftAP MAC = station MAC + 1, so the suffix is predictable from the chip's station MAC. Standard upstream convention, no customization by the vendor.
- **Open AP** (no WPA password on the SoftAP itself)
- **Captive portal**: `http://192.168.4.1`
- **Web UI title bar**: 登录 Xiaozhi-XXXX / "Login to Xiaozhi-XXXX"

## Tab structure

The web UI has 3 elements in the top tab bar:
1. **Wi-Fi Config** — main config tab (default selected)
2. **Advanced** — advanced settings (THIS is where Custom OTA URL lives)
3. **Language dropdown** (▾) — opens a modal language picker

## Tab 1 — Wi-Fi Config

### Sections (top-to-bottom)

**Saved Wi-Fi** — networks the device has previously connected to:
- `<home-ssid>` [×]   — connectable (presumably user's home wifi, also visible in scan at -72 dBm)
- `<vendor-factory-ssid>` [↑] [×]   — the seller-test wifi from NVS dump (the ↑ icon = "prioritize" or "set as primary")

> Note: the presence of `<home-ssid>` in saved list, despite our earlier NVS strings dump only showing `<vendor-factory-ssid>`, suggests either (a) the device did briefly associate with the user's home wifi before this session (auto-attempted during stock boot?), or (b) `strings` missed one of two SSID entries because of non-null-terminated layout. Worth re-examining the full NVS bytes if it matters.

**New Wi-Fi** — manual SSID/Password entry:
- `SSID:` (text input)
- `Password:` (text input)
- `[Connect]` (blue button)

**Wi-Fi scan list** — labeled "Select a 2.4G Wi-Fi from the list below:". Each entry is a hyperlink that pre-fills the SSID box. Lock icon if encrypted. Notable: device explicitly says **2.4 GHz** — 5 GHz APs filtered out, ESP32-S3 is 2.4-only anyway.

Shape of the list as rendered (SSIDs redacted — the live scan is location-identifying):
```
<home-ssid>                            (-72 dBm)  🔒
<5 other APs>                (-82 to -92 dBm)  🔒
```

Observations worth keeping from the live scan: entries are sorted by descending signal strength, a lock glyph marks encrypted APs, and one of the visible entries was a printer's Wi-Fi Direct AP — i.e. the list is a plain unfiltered 2.4 GHz scan, not a curated one.

## Tab 2 — Advanced ⭐

This is the high-value tab. Four controls:

| Control | Type | Default | What it does |
|---|---|---|---|
| **Custom OTA URL** | text input + [×] clear button | empty | overrides `CONFIG_OTA_URL` compiled default `https://api.tenclass.net/xiaozhi/ota/` |
| **Wi-Fi Max TX Power** | dropdown | `20 dBm` | max transmit power; lower = battery save, less range |
| **Remember BSSID when connecting to Wi-Fi** | checkbox | unchecked | pin to a specific AP MAC instead of roaming by SSID |
| **Enable Sleep Mode** | checkbox | ✓ checked | light/modem sleep when idle (battery save) |
| `[Save]` | button | — | persists settings to NVS, returns to main tab |

### Why Custom OTA URL matters

The OTA endpoint is responsible for handing the device its runtime WebSocket URL + token in its response JSON (see [protocol.md](protocol.md) for the full handshake):

```json
{
  "websocket": { "url": "wss://your.server/xiaozhi/v1/", "token": "..." },
  ...
}
```

So whoever owns the OTA URL owns the device's *entire* conversation backend. By exposing this URL as a captive-portal field, the stock firmware effectively offers a built-in "BYO backend" switch.

**Self-hosting path is therefore**:
1. Implement an OTA endpoint at e.g. `https://voice-toy.example.com/xiaozhi/ota/` that returns a JSON response with `websocket.url` pointed at our own WS server
2. Implement the WebSocket server (voice frame in/out, TTS commands, etc.)
3. Type that OTA URL into this Advanced tab, hit Save
4. Done — device pivots to our backend, no firmware change, no xiaozhi.me account, no traffic to api.tenclass.net

This is dramatically less work than the alternative (custom firmware build + flash + maintain).

## Tab 3 — Language picker

Modal dialog triggered by the ▾ in the top right. Currently selected: **English** (English/Chinese were the safe bets but the actual list is huge):
- English ✓ (current)
- Español
- فارسی
- Suomi
- Filipino
- Français
- עברית
- हिन्दी
- Hrvatski
- Magyar
- Bahasa Indonesia
- (list continues — at least ~30 languages typical for xiaozhi-esp32)

Implication: localization is built into the captive portal HTML server-side (LWIP/HTTPD bundled HTML strings, probably from upstream's `assets/lang/*.json`). Not user-relevant for self-hosting but useful when reading the upstream source.

## Cross-references

- Code: the captive portal HTML and its endpoint handler live in the upstream `wifi` component (the config-AP sources), not in the board directory
- Trigger function: `Board::EnterWifiConfigMode()` — called from `sp-esp32-s3-1.54-muma.cc:169` (touch) and `:254` (boot button) when `DeviceState == kDeviceStateStarting`
- OTA URL persistence: stored in NVS namespace `wifi`, key `ota_url` (string), read by `main/ota.cc` as `settings.GetString("ota_url")` with fallback to `CONFIG_OTA_URL`
- The Wi-Fi Config tab writes the `ssid` / `password` keys in that same `wifi` namespace. Note for anyone dumping their own device: the NVS partition on the as-shipped unit still contained the vendor's factory-test Wi-Fi credentials — production units are not always wiped before shipping, so treat any flash dump as credential-bearing and keep it off public storage.

## What this changes about the project plan

Before this confirmation: self-hosting required either (a) build & flash a custom firmware with our OTA URL hardcoded, or (b) hijack DNS for `api.tenclass.net` on our LAN. Both are real work.

After: self-hosting requires only **building the server**. Firmware stays stock. Device can roam between the tenclass backend and our own by re-entering captive portal and swapping the field.

Knock-on effects:
- Building and flashing a custom firmware drops in priority — we don't need to maintain a custom firmware fork until we want device-side features (UI tweaks, new commands) that the stock firmware can't reach.
- The capture work (pcap of the tenclass responses) is less essential — once we own the OTA endpoint we can log the protocol bytes server-side from our own clients without any pcap machinery.
- Migrating to a different board gets easier too — the captive portal is an upstream `xiaozhi-esp32` feature rather than a vendor-specific one, so other boards running the same stock firmware should expose the same Advanced tab. See [board-selection.md](board-selection.md) for the hardware comparison behind that migration.
