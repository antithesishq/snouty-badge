# Prebuilt calibration cart for hardware testing

`badge-calibrate.uf2`, built from the commit named in the git log of this
directory. Nothing to install: copy one file to the badge.

## Steps for the tester

0. The badge's kernel needs the core-1 cycle-counter fix (sycl-badge
   branch `fix/core1-dwt-trcena`, `DEMCR.TRCENA`); on a kernel without it
   the cart starts and shows nothing forever. Flash
   `sycl-os-kernel.uf2` built from that branch first, the same way as the
   cart below.
1. Put the badge in bootloader mode and plug it in over USB-C. It appears
   as a USB drive. Copy `badge-calibrate.uf2` onto it.
2. If you can, open the badge's USB serial console **before** starting the
   cart and log it to a file (macOS: `screen /dev/cu.usbmodem* 115200`, then
   `C-a H` to log; or `(stty raw; cat) < /dev/cu.usbmodemXXXX > capture.txt`;
   Linux: `/dev/ttyACM0`). The OS prints lines starting with `[CART] CAL`.
3. Start the cart from the badge menu. It runs its 20 kernels five times,
   about two seconds, then keeps showing a results page. Press A to cycle
   the three pages; B starts over.
4. Send back the console log, or, without a console, clear photos of all
   three pages (page 3 shows a checksum and a "late busy runs" count; say
   what that count is, it should be 0).
5. Also say which badge it was, in case two badges ever disagree.

What we do with it: `badge-bench/calibrate/fit.py` turns the capture into
`calibration.toml`, which makes badge-bench report calibrated milliseconds
instead of a lower bound. A capture from one badge is enough.
