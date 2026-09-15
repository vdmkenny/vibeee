; The first instructions after waking from a suspend to memory.
;
; Firmware leaves a sleeping machine's memory alone and, on waking, jumps to
; the address the operating system put in the ACPI firmware waking vector. It
; jumps there in real mode, with no stack worth the name, no descriptor
; tables, and paging off: exactly the state the machine was in before it ever
; booted. This is the few dozen instructions that get back from there.
;
; Copied into a page of low memory the allocator never hands out, and patched
; before the machine sleeps with the three things it cannot know: the page
; directory to bring paging back with, what CR4 must hold for that directory
; to be read correctly, and where in the kernel to land. Those sit at fixed
; offsets from the start of the page so the patching is three stores and no
; parsing; `kernel/sleep.zig` names the same offsets and the build checks the
; blob is long enough to hold them.
;
; Assembled to a flat binary by `zig build s3-trampoline`, which writes it out
; as bytes in `src/kernel/s3wake.zig`, generated and committed the way the
; syscall reference and the driver manifests are. Where it goes is given on
; the command line, because the kernel has to agree with it: the far jump
; below and the descriptor table it loads are absolute addresses, so this
; runs where it was assembled for or nowhere.

BITS 16
ORG ORIGIN

; The firmware enters here. Over the patched words first: they have to be at
; an address this side can compute without reading the code.
start:
    jmp short begin

    align 4
; Patched before sleeping. Offsets 4, 8 and 12 from the page's start.
cr3_value:      dd 0
cr4_value:      dd 0
entry_value:    dd 0

begin:
    cli
    cld
    ; Every segment flat and zero: the firmware's are whatever it left, and
    ; the descriptor load below reads through DS.
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    lgdt [gdt_pointer]

    ; Protected mode, and a far jump to load CS with a 32-bit descriptor.
    ; The jump is the instruction that actually changes how the next one is
    ; decoded, which is why it cannot be a near one.
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword 0x08:protected

BITS 32
protected:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    ; CR4 before CR3, and both before paging: a directory of four megabyte
    ; pages is read as one of four kilobyte pages unless the size extension
    ; is already on, and the first thing that would be fetched through it is
    ; this code.
    mov eax, [cr4_value]
    mov cr4, eax
    mov eax, [cr3_value]
    mov cr3, eax

    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    ; Paging is on and the very next fetch goes through it, so the directory
    ; handed over above has to map this page where it already is. The kernel
    ; puts that mapping back before it sleeps and takes it away again once it
    ; is home.
    mov eax, [entry_value]
    jmp eax

; A flat descriptor table, enough to be in protected mode with. The kernel's
; own is restored on the other side; this one exists only for the handful of
; instructions between here and there.
    align 8
gdt:
    dq 0x0000000000000000       ; null
    dq 0x00CF9A000000FFFF       ; code, base 0, limit 4 GiB
    dq 0x00CF92000000FFFF       ; data, base 0, limit 4 GiB
gdt_end:

gdt_pointer:
    dw gdt_end - gdt - 1
    dd gdt
