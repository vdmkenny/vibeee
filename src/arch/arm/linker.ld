/* vibeee arm linker script: the QEMU versatilepb layout.
 *
 * QEMU loads the ELF at 0x00010000 with RAM running from 0x00000000. The low
 * addresses are kept out of the image so the vector table, which the kernel
 * copies down at boot, owns them alone: an instruction at the exception
 * entry points that the loader did not put there is exactly the class of
 * surprise this script exists to prevent.
 *
 * design/12-arm-port.md §4.1.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x00010000;

    /* The vector table. Copied to address zero at boot rather than executed
     * where the loader left it, which is why it gets its own section. */
    .vectors : {
        KEEP(*(.vectors))
        . = ALIGN(16);
    }

    .text.boot : {
        *(.text.boot)
    }

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    __bss_start = .;
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }
    __bss_end = .;

    /* The boot stack, 64 KiB at the top of the image. Grows down into the
     * region past the bss, which nothing else uses once the kernel runs. */
    . = ALIGN(16);
    . += 64K;
    stack_top = .;

    /DISCARD/ : {
        *(.note .note.*)
        *(.comment .comment.*)
    }
}
