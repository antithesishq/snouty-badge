/*
 * snouty-genesis RAM cart: the pinned SDK's src/cart/cart_ram.ld (a6ce19f)
 * with one change, a 20 KB stack reservation instead of 32 KB, selected by
 * carts/snouty-genesis/build.zig (`ram_linker_script`, build/os_cart.zig).
 * The stack top, the memory map and every section are the SDK's.
 *
 * Why: the console (~141 KB), its sound synthesis and the two-player link
 * (lib/link.zig, lib/lockstep.zig) do not fit beside a 32 KB reservation.
 * The cart's stack peaks at about 6 KB (badge-bench --stack over Sonic 1
 * with sound, fast forward, the menu, About and the link screen; a link
 * race adds the state hash's 1.7 KB copy, not nested in a frame):
 * docs/LINK_PLAY.md and PLAN.md "Link cable play". Nothing on
 * core 1 checks the boundary (the OS sets no stack limit for the cart):
 * the reservation is this file's ASSERT only. Re-measure before raising
 * the cart's stack use.
 */

/*
 * Cart RAM Linker Script
 * 
 * Linker script is for building cart programs that run on Core 1
 * of the SYCL Badge OS. Carts built with this script are loaded into
 * and executed from RAM.
 *
 * Memory Map:
 *   Cart RAM:         0x20035100 - 0x20080000 (307KB process_ram)
 *
 * Usage:
 *   When building carts, use this linker script to ensure the cart
 *   is linked for the correct execution address.
 *
 * Requirements:
 *   - Cart binary must be <= 256KB
 *   - Entry point must be at vector table offset 4 (Reset_Handler)
 *   - Cart should use process_ram for all RAM needs
 */

ENTRY(_start)

MEMORY
{
    RAM(rwx) : ORIGIN = 0x20035100, LENGTH = 0x4AF00
}

SECTIONS
{
    /* MicroZig vector table - MUST be at the VERY start of flash (offset 0) */
    /* MicroZig exports this in "microzig_flash_start" section */
    /* ARM Cortex-M: [0] = initial SP, [1] = Reset_Handler */
    .cart_descriptor :
    {
        KEEP(*(.cart_descriptor))
    } > RAM

    /* Code and read-only data */
    .text :
    {
        . = ALIGN(4);
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > RAM

    /* ARM exception unwind tables */
    .ARM.extab : { *(.ARM.extab*) } > RAM
    .ARM.exidx :
    {
        __exidx_start = .;
        *(.ARM.exidx*)
        __exidx_end = .;
    } > RAM

    /* Initialized data: stored in flash, copied to RAM at startup */
    .data :
    {
        . = ALIGN(4);
        __data_start__ = .;
        *(.data*)
        . = ALIGN(4);
        __data_end__ = .;
    } > RAM

    /* Zero-initialized data */
    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end__ = .;
    } > RAM

    /* Heap starts after BSS */
    .heap (NOLOAD) :
    {
        . = ALIGN(8);
        __heap_start__ = .;
        /* Heap grows upward toward stack */
    } > RAM

    /* Stack at end of RAM, grows downward */
    /* snouty-genesis: 20 KB (the SDK reserves 32 KB); see the top. */
    __stack_size__ = 20K;
    __stack_top__ = ORIGIN(RAM) + LENGTH(RAM);
    __stack_limit__ = __stack_top__ - __stack_size__;

    /* Sanity checks */
    ASSERT(__bss_end__ <= __stack_limit__, "ERROR: BSS overflows into stack region")
    ASSERT((__stack_top__ & 0x7) == 0, "ERROR: Stack not 8-byte aligned")
}

/* Export symbols for cart startup code */
__ram_start__ = ORIGIN(RAM);
__ram_end__ = ORIGIN(RAM) + LENGTH(RAM);

/* Export symbols to stub out microzig boot, OS does this init */
microzig_bss_start = __ram_end__;
microzig_bss_end = __ram_end__;
microzig_data_start = __ram_end__;
microzig_data_end = __ram_end__;
microzig_data_load_start = __ram_end__;
