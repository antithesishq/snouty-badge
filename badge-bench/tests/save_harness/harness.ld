/* badge-bench tests/test_saves.py: lib/save.zig's badge backend linked at a
   fixed cart RAM address, no start code; the test calls the exports. */
ENTRY(h_supported)
MEMORY { ram (rwx) : ORIGIN = 0x20040000, LENGTH = 0x10000 }
SECTIONS {
    .text : { *(.text*) *(.rodata*) } > ram
    .data : { *(.data*) } > ram
    .bss (NOLOAD) : { __bss_start__ = .; *(.bss*) *(COMMON) __bss_end__ = .; } > ram
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.attributes) }
}
