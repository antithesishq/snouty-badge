# lib/tof_firmware.bin

The TMF8820/21/28 RAM application that lib/tof.zig downloads into the
sensor's bootloader at every power-up (2476 bytes, `0x9AC`, loaded at
`0x00200000`; vector table: initial SP `0x00208000`, reset `0x0020009D`).

- Source: SparkFun Qwiic TMF882X Arduino Library v1.0.2
  (<https://github.com/sparkfun/SparkFun_Qwiic_TMF882X_Arduino_Library>,
  commit f4be0ec, `src/tof_bin_image.c`, generated there by srecord),
  released by SparkFun under the MIT license.
- The image itself is ams OSRAM firmware, provided for use with ams
  parts only (the ams copyright notice in that library's host driver
  sources says so); it is used here unmodified with an ams TMF8820 on
  SparkFun's Qwiic Mini dToF Imager breakout.
- Extracted verbatim with `tools/tof_firmware_bin.py` (byte count checked
  against `tof_bin_image_length`).
- SHA-256: `b6c706c24b5af57d0c80d2d4586c2d8d7b6465f651446de1c2998690e7b04816`
