# WM8960 speaker silent on ReSpeaker 2-Mic Pi HAT — headphones work, speaker doesn't

*From a Raspberry Pi prototype that preceded the ESP32-S3 work — same voice device, earlier hardware.*

**Symptom**: with the upstream `wm8960-soundcard` device-tree overlay, the headphone jack plays audio
fine but the JST-PH speaker output is completely silent. `aplay -l` lists the card, playback reports
success, and **no kernel error is logged**. Nothing tells you what is wrong.

**Platform**: Raspberry Pi (Raspbian kernel), Seeed ReSpeaker 2-Mic Pi HAT v1.0, WM8960
codec over I²S, 8 Ω speaker on the JST-PH socket.

---

## Root cause

The upstream overlay does not declare a real `SPKVDD1` / `SPKVDD2` regulator. The kernel driver
therefore binds against *dummy* regulators, and — reasonably, from the driver's point of view —
conservatively **skips setting the `SPKL` / `SPKR` enable bits in the codec's PWR2 register (0x1A)**,
because as far as it knows the speaker amp rail is not powered.

On this HAT the silicon *is* physically powered. So the amp sits there, powered and disabled, and the
driver has no reason to report a problem. Headphones run off a different output path, which is why
they work and mask the issue.

## Fix

Force `PWR1` and `PWR2` with direct I²C writes after the driver has bound:

```bash
i2cset -f -y 1 0x1a 0x33 0xfe   # PWR1 = 0x1FE: VMID, VREF, AINL/R, ADCL/R, MICB
i2cset -f -y 1 0x1a 0x35 0xf8   # PWR2 = 0x1F8: DACL/R, LOUT1/ROUT1, SPKL/SPKR
```

**Register encoding** (this trips people up): each WM8960 transaction is 16 bits — a 7-bit register
address plus 9 bits of data — sent as two I²C bytes:

```
byte0 = (reg << 1) | data[8]
byte1 = data[7:0]
```

So `PWR2` (reg `0x1A`, data `0x1F8`) encodes as `0x35 0xF8`, not as `0x1A 0xF8`. The 9th data bit
lives in the low bit of the address byte.

## Ordering matters

Run the `amixer` calls **first**, then the register pokes. Setting volumes triggers a regmap sync that
can clobber `PWR2` if you poke it first — you get a working speaker that goes silent a second later,
which is a genuinely confusing failure mode.

Full init sequence, run once at boot from a systemd one-shot (`After=alsa-restore.service sound.target`):

```bash
CARD=wm8960soundcard

# --- mixer: DAC → output mixer routing is OFF and several volumes are 0 by default ---
amixer -c "$CARD" sset "Left Output Mixer PCM"            on
amixer -c "$CARD" sset "Right Output Mixer PCM"           on
amixer -c "$CARD" sset "Left Input Mixer Boost"           on
amixer -c "$CARD" sset "Right Input Mixer Boost"          on
amixer -c "$CARD" sset "Left Input Boost Mixer LINPUT1"   1     # 13 dB; 3 (29 dB) clips
amixer -c "$CARD" sset "Right Input Boost Mixer RINPUT1"  1
amixer -c "$CARD" sset "Speaker AC"                       5
amixer -c "$CARD" sset "Speaker DC"                       5
amixer -c "$CARD" sset "Speaker"                          115   # 0..127
amixer -c "$CARD" sset "Headphone"                        115   # 0..127
amixer -c "$CARD" sset "Playback"                         235   # 0..255 (DAC master)
amixer -c "$CARD" sset "Capture"                          30    # ~3 dB; 50 (20 dB) clips on close talking

# --- register pokes AFTER amixer ---
i2cset -f -y 1 0x1a 0x33 0xfe
i2cset -f -y 1 0x1a 0x35 0xf8

alsactl store
```

## Why I used the in-kernel overlay instead

As of early 2026 on Raspberry Pi OS (Bookworm), the vendor `seeed-voicecard` installer and the
community forks of it pulled in a 2023-era kernel via `dpkg-divert`, which costs time and pins you to
an old kernel. The **`wm8960-soundcard` overlay that ships with the current Raspbian kernel works
fine** — you just have to handle the speaker-amp power-up yourself,
which is the ten lines above.

## Verify

```bash
aplay -l                                                           # should list 'wm8960soundcard'
arecord -D plughw:wm8960soundcard -f S16_LE -r 16000 -c 2 -d 3 /tmp/t.wav
aplay   -D plughw:wm8960soundcard /tmp/t.wav
```

## Search terms

`WM8960 speaker no sound`, `ReSpeaker 2-Mic HAT speaker silent`, `wm8960-soundcard headphones work
speaker doesn't`, `SPKVDD dummy regulator`, `WM8960 PWR2 SPKL SPKR`, `i2cset wm8960 0x35 0xf8`.
