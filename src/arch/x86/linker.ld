/* vibeee kernel link script (x86, 32-bit).
 *
 * Higher-half kernel: loaded at physical 1 MiB, linked to run at 0xC0100000.
 * The low 3 GiB of every address space then belongs to user processes, and the
 * kernel is mapped identically in all of them so a syscall needs no CR3 change.
 *
 * `.boot` is the exception: it runs before CR0.PG is set, so it is linked at
 * its physical address and must be self-contained.
 */

KERNEL_VMA = 0xC0000000;

ENTRY(_start)

SECTIONS
{
    . = 1M;
    __kernel_phys_start = .;

    /* Pre-paging code and data. Offset 0 of the flat binary must be the stage2
     * entry stub, so `.text.boot` leads; the Multiboot header follows, well
     * inside the first 8 KiB the spec requires. */
    .boot ALIGN(4K) : {
        /* Offset 0 of the flat binary MUST be the stage2 entry stub: stage2
         * loads the image at 1 MiB and jumps to its first byte. Its own
         * section, placed first, because link order within `.text.boot` is
         * otherwise up to the linker. */
        KEEP(*(.text.boot.entry))
        KEEP(*(.text.boot))
        KEEP(*(.multiboot))
        *(.bootdata)
    }

    /* Everything past here is addressed virtually but loaded physically. */
    . += KERNEL_VMA;

    .text ALIGN(4K) : AT(ADDR(.text) - KERNEL_VMA) {
        *(.text .text.*)
    }

    .rodata ALIGN(4K) : AT(ADDR(.rodata) - KERNEL_VMA) {
        *(.rodata .rodata.*)
    }

    .data ALIGN(4K) : AT(ADDR(.data) - KERNEL_VMA) {
        *(.data .data.*)
    }

    .bss ALIGN(4K) : AT(ADDR(.bss) - KERNEL_VMA) {
        __bss_start = .;
        *(COMMON)
        *(.bss .bss.*)
        __bss_end = .;
    }

    __kernel_virt_end = .;
    __kernel_phys_end = . - KERNEL_VMA;

    /* Physical extents for the Multiboot a.out kludge (see multiboot.zig).
     * QEMU's `-kernel` ELF path loads by p_vaddr, which for a higher-half
     * kernel means writing past the end of RAM; the kludge states the physical
     * addresses explicitly and sidesteps the question. */
    __load_end_phys = LOADADDR(.data) + SIZEOF(.data);
    __bss_end_phys = LOADADDR(.bss) + SIZEOF(.bss);

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
        *(.note .note.*)
    }
}
