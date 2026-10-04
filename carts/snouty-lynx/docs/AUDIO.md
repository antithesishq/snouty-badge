# Hearing Snouty Lynx off the badge

M5 streams Mikey's four audio channels to the badge speaker (PLAN.md "M5
Sound: contract"). Two host tools turn that sound into WAV files so it can
be listened to on a laptop before anything is flashed. Both write 8-bit
unsigned mono 44,100 Hz WAVs (128 = silence), the badge firmware's
streaming format. Run every command from the repository root.

## 1. The core's sound: `run-lynx --wav`

```sh
zig build run-lynx -- carts/snouty-lynx/roms/raycast.lnx \
  carts/snouty-lynx/tools/scripts/m1_play.json 600 out/run-raycast --quiet --every 0 \
  --wav out/run-raycast/raycast.wav
zig build run-lynx -- ~/roms/lynx/hard_drivin.lnx - 1800 out/run-hd --quiet --every 0 \
  --wav out/run-hd/hard_drivin.wav          # local dump, never committed
zig build run-lynx -- ~/roms/lynx/blue_lightning.lnx - 900 out/run-bl --quiet --every 0 \
  --wav out/run-bl/blue_lightning.wav
```

The WAV holds `Lynx.audio_out` after every update: 735 samples (exactly
1/60 s) a frame. The splash updates do not step the core, so they write
735 samples of silence and one update is still 1/60 s. The input model is
the cart's (docs/RUNNING.md 2a). With no script (`-`) the splash ends by
itself at update 72.

This is the emulator's output with no rate control, menu, ramps or
underruns. If it sounds wrong here, the problem is in the core
(`core/audio.zig`, `core/mikey.zig`).

## 2. What the speaker gets: `badge-bench --wav`

```sh
zig build -Dcart=snouty-lynx
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --wav out/bench-lynx/m3_scrub.wav
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --script carts/snouty-lynx/tools/scripts/m2_play.json \
  --frames 400 --wav out/bench-lynx/m2_play.wav
# a dump from a drive image (local only):
python3 tools/make_romfs.py out/lynx-romfs.img ~/roms/lynx/hard_drivin.lnx
badge-bench/bench.sh zig-out/firmware/snouty-lynx.elf --no-config --romfs out/lynx-romfs.img \
  --frames 1800 --wav out/bench-lynx/hard_drivin.wav
```

The first command uses the bench toml (`badge-bench/carts/snouty-lynx.toml`:
`m3_scrub.json`, 480 updates, the raycast drive fixture). `--no-config`
drops it; with no script no button is pressed and the splash runs out by
itself.

The bench runs the real cart ELF. The fake OS mixes the cart's ring the
way the new firmware does (badge-bench README, "Streaming audio"): two
512-sample buffers at the start word, then one every 512 samples of wall
time. A frame's wall time is at least the LCD period the OS picks for
60 fps vsync, 16.74 ms. The WAV is the mixed stream from the start word
on, with silence wherever a buffer found the ring short. That means it
includes the frontend's rate-controlled resampling, the menu and scrub
ramps and every underrun. The report's `audio:` lines give the numbers:

```
audio: streaming started in frame F (ring 4096 samples at 0x...); N mixes of 512: S samples consumed (T s)
  start-up silence 1,024 samples; underruns U samples in M mixes (first in frame G); queue at each mix min A mean B max C
```

- **Start-up silence** is expected. The OS mixes two buffers when audio
  starts, before the cart's first push can land.
- **Underruns** should be 0 while the game runs. Silence after the menu
  opens is the frontend deliberately going quiet, not an underrun of the
  game.
- **Queue:** the frontend aims for 1,470 queued samples at each push. At
  each mix it should sit around 950..2,200 while the game runs.
- With `--json`, `bench.json` has `audio.frames`: the queue, samples
  consumed and underruns at the end of every frame. Plot it to see the
  rate control settle.

## 3. Listening checklist

Listen on headphones and on a laptop speaker; the badge speaker is
worse than both. For each WAV:

1. **Pitch.** A held tone (raycast's beeps, a menu jingle) sounds at the
   right note. Compare it with the frequency from the register values:
   16 MHz / (16 << clock select) / (BACKUP + 1) / the LFSR period. If the
   bench WAV sounds lower or higher than the run-lynx one, the rate
   control is resampling too far (it should stay well under 1%, a few
   cents).
2. **Clicks at frame edges.** No tick or buzz at 60 Hz. A 60 Hz buzz
   means the per-frame bins are not continuous across `step_frame` calls
   (core), or the push drops or repeats samples at the ring wrap
   (frontend). In the bench WAV, a click every few seconds that is
   missing from the run-lynx WAV points at the rate control's
   nearest-neighbour step.
3. **Levels and clipping.** Loud but not flat-topped. Few samples should
   sit at 0 or 255; long runs there mean the mix gain is too high for that
   game. Silence is 128, not 0, so there should be no thump when sound
   starts.
4. **Menu and scrub ramps.** Open the menu (m3_scrub opens it at update
   314): the sound fades to silence over 64 samples (1.5 ms) with no
   click and stays silent through the scrub. On resume (B at 415), 735
   samples of silence come first, then the game, with no burst of stale
   sound from before the menu.
5. **Underruns.** No dropouts while the game runs (`underruns 0` in the
   bench report before the menu opens). A short gap right after a heavy
   frame means the queue target is too low for that frame's cost.

Quick numbers without listening (system python3 has numpy):

```sh
python3 - out/run-raycast/raycast.wav <<'EOF'
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); x = np.frombuffer(w.readframes(w.getnframes()), np.uint8).astype(float) - 128
print(f"{len(x) / 44100:.2f} s, rms {np.sqrt((x ** 2).mean()):.1f}, peak {abs(x).max():.0f}, "
      f"clipped {(np.abs(x) >= 127).mean() * 100:.2f}%")
s = np.abs(np.fft.rfft(x * np.hanning(len(x))))
print(f"dominant {np.argmax(s[1:]) * 44100 / len(x) + 44100 / len(x):.1f} Hz, "
      f"60 Hz bin {s[round(60 * len(x) / 44100)] / s.max():.3f} of the peak")
EOF
```
