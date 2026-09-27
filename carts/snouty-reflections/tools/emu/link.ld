/* Bench ELF layout for the emulator (tools/emu/build.sh). Everything lives
 * in one flat RAM region at the RP2354 SRAM base: the model assumes code and
 * data both in zero-wait-state SRAM, like the cart on the badge. */
ENTRY(_start)
MEMORY { RAM(rwx) : ORIGIN = 0x20000000, LENGTH = 0x80000 }
SECTIONS {
  .text : { . = ALIGN(4); *(.text*) *(.rodata*) . = ALIGN(4); } > RAM
  .ARM.exidx : { *(.ARM.exidx*) } > RAM
  .data : { . = ALIGN(4); *(.data*) . = ALIGN(4); } > RAM
  .bss (NOLOAD) : { . = ALIGN(4); *(.bss*) *(COMMON) . = ALIGN(4); } > RAM
  .fb (NOLOAD) : { . = ALIGN(0x2000); *(.fb) } > RAM
}
