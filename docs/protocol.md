# Finding — xiaozhi protocol spec (server-builder's view)

**Date**: 2026-05-21
**Method**: read from the upstream open-source firmware, [78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) (MIT) — the same firmware that ships on these devices:
- `main/ota.cc` (492 lines, OTA client)
- `main/protocols/protocol.h` (base interface)
- `main/protocols/websocket_protocol.{h,cc}` (WS client)
- `docs/websocket.md` (upstream's own spec, 530 lines)

**Purpose**: catalog every wire-format detail a self-hosted backend has to honor. This document was the design input for the server described in [server-architecture.md](server-architecture.md).

---

## Two endpoints to implement

To replace `api.tenclass.net` for one device, we implement two HTTP/WS endpoints:

1. **OTA endpoint** — plain HTTPS, returns a JSON config including the WebSocket URL the device should use for actual voice traffic. Called once at device boot (and possibly periodically thereafter).
2. **WebSocket endpoint** — `wss://`, carries Opus audio (binary frames) + control messages (JSON text frames) bidirectionally. This is where ASR + LLM + TTS happens.

Optionally a third (MQTT broker) but the device uses WebSocket as primary when both are present. **We can ignore MQTT for v1.**

---

## 1. OTA endpoint

### 1.1 What the device calls

URL: whatever the captive portal's "Custom OTA URL" field is set to (NVS namespace `wifi`, key `ota_url`), falling back to `CONFIG_OTA_URL` (default `https://api.tenclass.net/xiaozhi/ota/`). The trailing slash is **not** significant — [`ota.cc:464-469`](https://github.com/78/xiaozhi-esp32/blob/417f52d7597b85f3dfc6f5283bdc66df34fbd5fe/main/ota.cc#L464) inserts the separator when it is missing, so `https://my.host/x` and `https://my.host/x/` both derive the same activation URL.

Method: `POST` if `Board::GetSystemInfoJson()` returns a non-empty body (almost always), `GET` otherwise.

Headers always sent:
```
Activation-Version: "1"   (or "2" if eFuse USER_DATA holds a 32-byte serial number)
Device-Id:          <chip station MAC>          e.g. "aa:bb:cc:dd:ee:ff"
Client-Id:          <board UUID>                e.g. "00000000-1111-2222-3333-444444444444"
Serial-Number:      <eFuse serial>              (only when present)
User-Agent:         <SystemInfo::GetUserAgent()>
Accept-Language:    <Lang::CODE>                e.g. "en-US" or "zh-CN"
Content-Type:       application/json
```

Body: `Board::GetSystemInfoJson()` — JSON describing the device (board class, firmware version, MAC, partition info, free heap, etc.). The server can ignore this for v1; it's useful later for firmware update decisions.

### 1.2 Response JSON schema

All top-level sections optional. Device handles each independently — sections it understands get parsed, unknowns ignored:

```json
{
  "activation": {
    "code":        "1234",
    "message":     "请在 xiaozhi.me 上输入激活码",
    "challenge":   "<random string>",
    "timeout_ms":  60000
  },
  "websocket": {
    "url":      "wss://your.host/xiaozhi/v1/",
    "token":    "<opaque-string>",
    "version":  1
  },
  "mqtt": {
    "endpoint":        "mqtt.your.host",
    "client_id":       "...",
    "username":        "...",
    "password":        "...",
    "publish_topic":   "device-server",
    "subscribe_topic": "null"
  },
  "server_time": {
    "timestamp":       1716246000000,
    "timezone_offset": 480
  },
  "firmware": {
    "version": "1.4.0",
    "url":     "https://your.host/fw/1.4.0.bin",
    "force":   0
  }
}
```

#### Per-section behavior

**activation** — if `code` is a non-empty string, the device displays it on LCD and enters `kDeviceStateActivating`. It will retry POST to `<ota_url>/activate` (see 1.3) every few seconds until the activation succeeds. `timeout_ms` is how long the whole activation attempt is allowed to run.

**websocket** — every key (`url`, `token`, `version`, anything else string-or-number) is copied verbatim into NVS namespace `"websocket"`. When the device opens a voice channel later, `WebsocketProtocol::OpenAudioChannel()` reads `url`, `token`, `version` from this namespace.
- `url`: full `wss://` URL the device connects to.
- `token`: passed as `Authorization: Bearer <token>` header.
- `version` (optional, defaults 1): binary protocol version (see §2.3).

**mqtt** — same persistence pattern as websocket but in NVS namespace `"mqtt"`. Used by the MQTT/UDP protocol path. **Skip for v1.**

**server_time** — if `timestamp` (ms since epoch) is a number, device calls `settimeofday()`. `timezone_offset` (minutes) shifts wall clock. Useful so the LCD clock and TLS cert verification work without NTP. Include this in v1, it's trivial.

**firmware** — if `version` is newer than current (semver compare), device sets `has_new_version_ = true` and may auto-pull the binary from `url`. If `force == 1`, treated as newer regardless. **For v1 just omit this section** — device skips OTA upgrade if absent.

### 1.3 Activation sub-endpoint (deferable for v1)

URL: the OTA URL with `activate` appended; upstream normalises the separator either way (see §1.1).

Method: `POST`.
Headers: same as 1.1.
Body: ESP32-S3 with HMAC eFuse + `has_serial_number_`:
```json
{
  "algorithm":     "hmac-sha256",
  "serial_number": "...",
  "challenge":     "...",
  "hmac":          "<hex(HMAC-SHA256(Key0, challenge))>"
}
```
Or `{}` if no serial number burned.

Response status codes:
- `200`: activated
- `202`: still pending (device retries)
- anything else: error

**For our self-host v1 we just skip activation entirely** — return an OTA response without an `activation` section and the device goes straight to `kDeviceStateIdle`. We can add activation later if we want device-account binding.

### 1.4 Minimum viable OTA response (for v1)

```json
{
  "websocket": {
    "url":   "wss://our.host/xiaozhi/v1/",
    "token": "anything-non-empty",
    "version": 1
  },
  "server_time": {
    "timestamp":       <Date.now() in ms>,
    "timezone_offset": <your tz minutes>
  }
}
```

That's it. Two sections. Device boots → calls OTA → gets this → saves the WS URL to NVS → opens audio channel to our WS server on next wake/button event.

---

## 2. WebSocket endpoint

### 2.1 Connection

URL: whatever we returned as `websocket.url`. Connection is `wss://` (TLS) — device's network stack handles cert validation against the system CA bundle (no pinning, regular CAs work).

Headers in the HTTP upgrade:
```
Authorization:    Bearer <token>     (added even if our token has no "Bearer " prefix)
Protocol-Version: 1                   (or 2 / 3)
Device-Id:        <MAC>
Client-Id:        <UUID>
```

These let the server tie this connection to a specific device.

### 2.2 Hello handshake

**Step 1 — device sends first JSON text frame:**
```json
{
  "type": "hello",
  "version": 1,
  "features": {
    "aec": true,    // only if CONFIG_USE_SERVER_AEC was set at compile time
    "mcp": true     // always if MCP support compiled in
  },
  "transport": "websocket",
  "audio_params": {
    "format":         "opus",
    "sample_rate":    16000,
    "channels":       1,
    "frame_duration": 60       // OPUS_FRAME_DURATION_MS at compile time, usually 60
  }
}
```

**Step 2 — server MUST respond within 10 seconds:**
```json
{
  "type":      "hello",
  "transport": "websocket",      // device REQUIRES exactly this string
  "session_id": "<server picks>",
  "audio_params": {
    "format":         "opus",
    "sample_rate":    24000,    // downlink rate, server picks (commonly 24k for TTS)
    "channels":       1,
    "frame_duration": 60
  }
}
```

If the server doesn't send `transport == "websocket"` or doesn't respond in 10s, device fires `on_network_error_` and shows a "cannot connect" alert.

The `session_id` from the server flows into every subsequent device-originated JSON message.

### 2.3 Binary audio framing (3 variants)

Selected by the `version` field in the OTA response's `websocket` section. Default v1.

**v1 — raw Opus** (simplest, recommended for our v1 server):
- Binary WS frame body = raw Opus packet bytes. Nothing else.
- Both directions.

**v2 — 16-byte header + payload** (use when server-side AEC needed; carries timestamp):
```
struct BinaryProtocol2 {
    uint16_t version;       // network byte order
    uint16_t type;          // 0 = OPUS, 1 = JSON
    uint32_t reserved;
    uint32_t timestamp;     // ms, used for server-side AEC alignment
    uint32_t payload_size;
    uint8_t  payload[];
};
```
All multi-byte integers network byte order.

**v3 — 4-byte header + payload** (lightweight):
```
struct BinaryProtocol3 {
    uint8_t  type;
    uint8_t  reserved;
    uint16_t payload_size;   // network byte order
    uint8_t  payload[];
};
```

### 2.4 JSON messages (text frames) — full type table

| Direction | `type` | Other fields | Meaning |
|---|---|---|---|
| D → S | `hello` | as above | handshake step 1 |
| D → S | `listen` | `session_id`, `state ∈ {start, stop, detect}`, `mode ∈ {auto, manual, realtime}`, (`text` when `state="detect"`) | mic open/close or wake-word detected |
| D → S | `abort` | `session_id`, `reason ∈ {wake_word_detected, ...}` | user interrupted TTS playback |
| D → S | `mcp` | `session_id`, `payload` (JSON-RPC 2.0) | tool-call response / device capability discovery |
| S → D | `hello` | as above | handshake step 2 |
| S → D | `stt` | `session_id`, `text` | ASR result (display as subtitle) |
| S → D | `llm` | `session_id`, `emotion`, `text` | persona/emotion change |
| S → D | `tts` | `session_id`, `state ∈ {start, stop, sentence_start}`, `text` (when sentence_start) | TTS lifecycle + sentence subtitle |
| S → D | `mcp` | `session_id`, `payload` | tool-call invocation (e.g. set LED color) |
| S → D | `system` | `session_id`, `command ∈ {reboot}` | system control |
| S → D | `alert` | `session_id`, `status`, `message`, `emotion` | popup with sound |
| S → D | `custom` | `session_id`, `payload.message` | escape hatch (compile-time gated) |

`session_id` is created server-side in the hello response and echoed in everything else.

### 2.5 Typical session flow

```
[device boots, wakes wifi, gets OTA → has wss URL + token]

D: connect wss + headers
D → S: {"type":"hello", "audio_params":{16kHz/opus/1ch/60ms}, ...}
S → D: {"type":"hello", "transport":"websocket", "session_id":"...", "audio_params":{24kHz/opus/1ch/60ms}}

[user says wake word or presses button]
D → S: {"type":"listen", "state":"start", "mode":"auto", "session_id":"..."}
D → S: [binary opus frame] × N   ← user voice, 16kHz frames
S → D: {"type":"stt", "text":"用户说的话", "session_id":"..."}
S → D: {"type":"llm", "emotion":"happy", "text":"😀", "session_id":"..."}
S → D: {"type":"tts", "state":"start", "session_id":"..."}
S → D: {"type":"tts", "state":"sentence_start", "text":"我来回答你", "session_id":"..."}
S → D: [binary opus frame] × N   ← TTS, 24kHz frames
S → D: {"type":"tts", "state":"stop", "session_id":"..."}

[either side may close; auto-mode loops back to listen automatically]
```

The mic stops being streamed to server while TTS is playing (device's local rule, to avoid mic→speaker→mic loop without AEC).

---

## 3. Audio codec details

| Property | Uplink (D→S) | Downlink (S→D) |
|---|---|---|
| Format | Opus | Opus |
| Sample rate | 16 kHz (advertised in device hello) | 24 kHz (advertised in server hello, configurable) |
| Channels | 1 (mono) | 1 (mono) |
| Frame duration | 60 ms typical (compile-time `OPUS_FRAME_DURATION_MS`) | 60 ms typical |
| TLS | yes (wss) | yes (wss) |
| Authentication | header `Authorization: Bearer <token>` | n/a |

The device handles sample-rate mismatch via on-device resampling — but our v1 server should still announce a 24kHz downlink (or just match 16k both ways for simpler synthesis).

---

## 4. Minimum viable server checklist (for v1 self-host)

In order of value:

| # | Component | Why it's needed |
|---|---|---|
| 1 | HTTPS OTA endpoint that returns `{websocket, server_time}` | Without this device never finds our WS server |
| 2 | WSS WebSocket endpoint accepting `Authorization: Bearer ...` and the device hello | Without this the device can't open a voice channel |
| 3 | Send a valid server hello within 10 s with `transport: "websocket"` + `session_id` | Without this device times out |
| 4 | Accept and decode incoming Opus frames (16 kHz mono) | Without this we can't hear the user |
| 5 | An ASR backend (Whisper / Azure / Google STT / 阿里 / ...) | Convert user audio → text |
| 6 | An LLM call (Anthropic / OpenAI / 本地) returning text | Generate response |
| 7 | A TTS backend (Azure / Google / Tencent / 本地) returning audio | Voice output |
| 8 | Encode TTS audio to Opus 24 kHz mono, push as binary frames | Send to device |
| 9 | Send the `{type:"tts", state:"start"}` then `{state:"stop"}` JSON markers around the binary | Device needs these to enter/exit Speaking state |
| 10 | Send `{type:"stt", text}` and `{type:"llm", emotion}` for the LCD subtitle | Nice but not strictly required for audio loop |

**Skip for v1:**
- Activation flow (entirely)
- MQTT/UDP alternative protocol
- MCP tool calls
- Server-side AEC (just don't advertise `aec: true`)
- Firmware OTA upgrade
- `alert`, `custom`, `system` messages

---

## 5. Practical implementation notes

### Use protocol v1 (raw Opus) for first iteration
Skip v2/v3 framing entirely. Just emit raw Opus packets as binary WS frames. Device handles. v2/v3 give you timestamps + interleaved JSON-in-binary; not worth the complexity for a first server.

### Cert handling
Device uses system CA bundle, no pinning. Standard Let's Encrypt cert on the host works. No need for our own CA.

### Token validation
We control both ends so the token can be literally anything non-empty in v1. Later we can verify it ties to a known `Device-Id`/`Client-Id` pair from headers.

### Session lifecycle
Each WebSocket connection is one session. Device opens on wake/button, may keep open for a while in auto-continue mode, closes when user is done. Don't hold long-lived state per session — the device will reconnect cleanly.

### Buffering downlink Opus
TTS engines usually produce PCM. Need to:
1. Resample PCM → 24 kHz mono
2. Encode → Opus, frame_duration matching what we advertised
3. Send each Opus packet as one binary WS frame, paced at roughly real-time (don't dump 5 seconds of audio in one burst — device buffer is small)

### The "session_id" is opaque to the device
Pick any short string. UUID4 is fine. Echo it back from the device.

---

## 6. Things this document doesn't cover (yet)

- MQTT/UDP alternative protocol — see upstream [docs/mqtt-udp.md](https://github.com/78/xiaozhi-esp32/blob/417f52d7597b85f3dfc6f5283bdc66df34fbd5fe/docs/mqtt-udp.md)
- MCP (model context protocol for IoT tool calls) — see upstream [docs/mcp-protocol.md](https://github.com/78/xiaozhi-esp32/blob/417f52d7597b85f3dfc6f5283bdc66df34fbd5fe/docs/mcp-protocol.md) and [docs/mcp-usage.md](https://github.com/78/xiaozhi-esp32/blob/417f52d7597b85f3dfc6f5283bdc66df34fbd5fe/docs/mcp-usage.md)
- Server-side AEC implementation details — see upstream docs/mqtt-udp.md, where AEC matters most
- The actual `Board::GetSystemInfoJson()` payload — not decoded here; a v1 server can ignore it
- Firmware update flow (`Ota::Upgrade`) — straightforward HTTP GET of a binary, decode ESP32 image header, write to inactive OTA partition

---

## 7. Where to plug in our existing voice_toy backend

The existing Pi-era `voice_toy/` (likely Python) backend already has STT/LLM/TTS plumbing. Reuse it by:
1. Adding a small HTTPS endpoint `/xiaozhi/ota/` returning the JSON in §1.4
2. Adding a WSS endpoint `/xiaozhi/v1/` running the loop in §2.5
3. Routing the user audio through the existing STT/LLM/TTS pipeline
4. Encoding the response audio to Opus (new dep: `opuslib` / `pyogg` / similar)
5. Hosting behind a TLS-terminating reverse proxy (caddy / nginx / cloudflare tunnel)

The hardest new piece is **Opus encoding/decoding**. Everything else is grafting onto what's there.
