#!/usr/bin/env python3
"""Extract the TMF882x RAM application from SparkFun's tof_bin_image.c.

    tools/tof_firmware_bin.py <SparkFun_Qwiic_TMF882X_Arduino_Library>/src/tof_bin_image.c lib/tof_firmware.bin

Run once to make lib/tof_firmware.bin (committed); see
lib/tof_firmware.NOTICE.md for where the image comes from. Checks the byte
count against the file's tof_bin_image_length.
"""
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index('{', src.index('tof_bin_image[]')) + 1: src.index('};')]
data = bytes(int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{2})\b', body))
length = int(re.search(r'tof_bin_image_length\s*=\s*0x([0-9A-Fa-f]+)', src).group(1), 16)
assert len(data) == length, (len(data), length)
open(sys.argv[2], 'wb').write(data)
print(len(data))
