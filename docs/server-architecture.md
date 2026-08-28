# Self-hosted backend — architecture

A Python backend that speaks the xiaozhi WebSocket protocol natively — the same protocol the stock
firmware on the ESP32-S3 board already speaks. It replaces the vendor cloud (`api.tenclass.net`) for
devices you own, without touching the firmware.

The wire format it implements is specified in [protocol.md](protocol.md); the reason no re-flashing is
needed is in [captive-portal-ota-finding.md](captive-portal-ota-finding.md).

> This document describes the design of a private implementation. The server source is not part of this
> repository — what is published here is the architecture and the protocol work behind it.

---

## Layering

```
app.py              entry point — starts the HTTP and WebSocket asyncio tasks
auth.py             stateless HMAC-SHA256 device token (generate + verify)
ota.py              HTTP /xiaozhi/ota/ endpoint (aiohttp)

transports/         per-device wire format — one file per device type
  base.py             abstract Transport interface
  xiaozhi_ws.py       xiaozhi protocol over WebSocket, binary v1 (raw Opus)

core/               device-agnostic — the same code drives ESP32, mobile, and SBC clients
  session.py          per-connection state machine
  pipeline.py         orchestration: ASR → LLM → TTS
  conversation.py     cross-device per-user state

providers/          swappable AI backends, called from the pipeline
  asr/                speech-to-text
  llm/                language models
  tts/                text-to-speech
```

**Why this shape.** The constraint that drove it: three very different clients (an ESP32-S3 speaking a
binary Opus protocol, a Flutter app, and a Linux SBC) must share one conversation. If transport
concerns leak into the conversation logic, every new client type forces a rewrite of the core.

So the split is by *rate of change*, not by feature:

- **`transports/`** — the only layer that knows about wire formats. A new device type is one new file
  here. Nothing else changes.
- **`core/`** — knows about sessions, turn-taking, and conversation state. Never parses a frame,
  never calls a vendor API.
- **`providers/`** — knows about one vendor API each, behind a common interface, so an ASR outage is
  a config change rather than a code change.

## Design decisions worth calling out

**Stateless auth.** Device tokens are HMAC-SHA256 over the device identity plus an expiry, verified
without a database round-trip. A small embedded client cannot hold a session cookie across power
cycles, and the OTA response is the only place a token can be handed over — so the token has to be
self-verifying.

**Provider fallback chains.** ASR and TTS are each configured as an ordered list rather than a single
provider. When the primary fails or rate-limits, the pipeline falls through to the next one instead of
dropping the turn. On free API tiers this is the difference between a toy that works and one that
works most of the time.

**Emotion tagging drives the display.** The LLM is asked to tag each reply with an emotion from a fixed
set; the tag rides along with the audio and selects a face on the device's screen. Keeping the emotion
vocabulary fixed and server-side means the firmware only has to know how to render N faces — the
expressiveness lives in the prompt, where it can be changed without re-flashing.

**Opus in, Opus out.** The device sends and expects Opus frames. Transcoding is confined to the
provider adapters, so the transport layer moves bytes it never has to understand.

## Operational shape

- Two listeners: HTTP for the OTA handshake, WebSocket for voice traffic.
- The device is pointed at the server by typing the OTA URL into the stock captive portal's Advanced
  tab — no custom firmware, no DNS interception.
- Designed for a LAN or a private tunnel; the auth model is a single shared signing key, which is
  appropriate for a personal deployment and would need per-device keys to go further.

## Honest limitations

- No test suite; verification has been manual, plus scripted fake-device clients that replay the
  protocol without hardware.
- Single-tenant by default — the mapping from device ID to user is a config table, not a user system.
- Latency is dominated by the ASR and LLM providers, not by the transport.
