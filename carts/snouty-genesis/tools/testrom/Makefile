# Snouty test ROM (see README.md). Needs gcc-m68k-linux-gnu,
# binutils-m68k-linux-gnu, z80asm (Debian/Ubuntu packages) and python3.
# `make BUILD=dir` puts every intermediate file in dir; build.sh wraps this.

BUILD  ?= build
CROSS  ?= m68k-linux-gnu-
CC      = $(CROSS)gcc
LD      = $(CROSS)ld
OBJCOPY = $(CROSS)objcopy
Z80ASM ?= z80asm
PYTHON ?= python3

# -m68000: plain 68000 code, no 68020 instructions; no libgcc (the Linux
# toolchain's libgcc is 68020+), so main.c avoids 32-bit multiply/divide.
# -frandom-seed and no -g keep the image independent of paths and time.
CFLAGS  = -m68000 -Os -std=gnu11 -ffreestanding -fno-builtin -nostdlib \
          -fno-pic -fno-common -fno-asynchronous-unwind-tables \
          -fomit-frame-pointer -Wall -Wextra -Werror -frandom-seed=snouty-test
ASFLAGS = -m68000
LDFLAGS = -T md.ld -nostdlib --build-id=none -N -z noexecstack --no-warn-rwx-segments

$(BUILD)/snouty-test.bin: $(BUILD)/snouty-test.elf fixup.py
	$(OBJCOPY) -O binary $< $(BUILD)/raw.bin
	$(PYTHON) fixup.py $(BUILD)/raw.bin $@ 16384

$(BUILD)/snouty-test.elf: $(BUILD)/crt0.o $(BUILD)/main.o md.ld
	$(LD) $(LDFLAGS) -o $@ $(BUILD)/crt0.o $(BUILD)/main.o

$(BUILD)/crt0.o: crt0.s $(BUILD)/z80.bin
	$(CC) -c $(ASFLAGS) -x assembler -Wa,-I$(BUILD) -o $@ crt0.s

$(BUILD)/main.o: main.c
	@mkdir -p $(BUILD)
	$(CC) -c $(CFLAGS) -o $@ main.c

$(BUILD)/z80.bin: z80.s
	@mkdir -p $(BUILD)
	$(Z80ASM) -o $@ z80.s

clean:
	rm -rf $(BUILD)

.PHONY: clean
