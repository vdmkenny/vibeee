/* User program layout.
 *
 * Loaded at 0x40000000: well clear of the null page so a null dereference
 * faults, and far below the kernel base at 0xC0000000.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x40000000;

    .text : { *(.text .text.*) }
    .rodata ALIGN(4K) : { *(.rodata .rodata.*) }
    /* vibeee's ELF notes (a program's icon). Kept against section garbage
     * collection, placed in the read-only segment, and located by PT_NOTE. */
    .note.vibeee : { KEEP(*(.note.vibeee .note.vibeee.*)) }
    .data ALIGN(4K) : { *(.data .data.*) }
    .bss ALIGN(4K) : { *(COMMON) *(.bss .bss.*) }

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.note .note.*) }
}
