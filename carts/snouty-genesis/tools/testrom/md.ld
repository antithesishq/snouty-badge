/* Snouty test ROM linker script: ROM at 0, work RAM at 0xFF0000. The stack
   occupies the top 512 bytes of RAM (SSP 0xFFFE00 grows down), so data and
   bss stay below 0xFFFE00. Section order is fixed for a deterministic image. */
OUTPUT_FORMAT("elf32-m68k")
OUTPUT_ARCH(m68k)
ENTRY(_start)

MEMORY
{
    rom (rx)  : ORIGIN = 0x000000, LENGTH = 0x8000
    ram (rwx) : ORIGIN = 0xFF0000, LENGTH = 0xFC00
}

SECTIONS
{
    .text : {
        KEEP(*(.vectors))
        *(.text.start)
        *(.text .text.*)
        . = ALIGN(2);
    } > rom

    .rodata : {
        *(.rodata .rodata.*)
        . = ALIGN(2);
    } > rom

    .data : {
        _data_start = .;
        *(.data .data.*)
        . = ALIGN(2);
        _data_end = .;
    } > ram AT > rom
    _data_load = LOADADDR(.data);

    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss .bss.* COMMON)
        . = ALIGN(2);
        _bss_end = .;
    } > ram

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.gnu.attributes) }
}
