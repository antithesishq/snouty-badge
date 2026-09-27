# Prebuilt carts for hardware testing

Built from tag `m1.1`. Nothing to install: copy one file to the badge.

- `snouty-reflections-m1.1.uf2`: the demo as shipped.
- `snouty-reflections-m1.1-timing.uf2`: same, plus a readout in the top-left
  corner: render microseconds, fps, dither mode letter (B or N).

## Steps for the tester

1. Put the badge in bootloader mode and plug it in over USB-C. It appears
   as a USB drive.
2. Copy `snouty-reflections-m1.1-timing.uf2` onto the drive.
3. Pick the cart in the badge menu. Let it run one full orbit (30 s).
4. Report back: the **highest** microseconds value you see in the corner
   during the orbit, and the fps next to it. A photo of the corner is fine.
   Also say whether the picture stutters or tears.
5. Optional: press B to toggle dithering off and on (letter N / B) and say
   which looks better on the real panel. Press the joystick for the OS fps
   overlay as a second opinion.

What we expect: the emulated model says 32 to 35 ms per frame, so a
readout between 35,000 and 45,000 us with a steady 20 fps means the model
holds. Above 50,000 us means the cart is dropping below its 20 fps lock
and we switch to the half-resolution path.
