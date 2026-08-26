; vibeee stage2, real-mode loader.
;
; Runs at 0x8000, loaded by stage1. Responsibilities:
;   1. Enable A20
;   2. Collect the E820 memory map
;   3. Locate the ACPI RSDP
;   4. Load the kernel (flat binary) to physical 1 MiB
;   5. Build a BootInfo and enter protected mode at the kernel's first byte
;
; The kernel is a flat binary, not ELF: its first byte is the entry stub
; (see src/arch/x86/flatboot.zig), which spares this file an ELF parser written
; in 16-bit assembly, code that would be painful to debug on a machine with no
; serial port.
;
; Fields marked PATCHED are filled in by tools/mkimage.zig once the real sizes
; are known.

BITS 16
ORG 0x8000

KERNEL_PHYS     equ 0x100000        ; where the kernel lands
ROOTFS_PHYS     equ 0x1000000       ; 16 MiB: clear of the kernel and its heap
LOAD_BUF_SEG    equ 0x2000          ; 0x20000: staging buffer for disk reads
CHUNK_SECTORS   equ 64              ; 32 KiB per INT 13h call
BOOTINFO_ADDR   equ 0x6000
E820_BUF        equ 0x7000          ; scratch for one E820 entry

; BootInfo field offsets. Mirrored by comptime asserts in
; src/kernel/bootinfo.zig, so a layout change breaks the build rather than
; silently producing a kernel that misreads its own boot data.
BI_MAGIC        equ 0
BI_VERSION      equ 4
BI_SOURCE       equ 6
BI_KERNEL_PHYS  equ 8
BI_KERNEL_LEN   equ 12
BI_ROOTFS_PHYS  equ 16
BI_ROOTFS_LEN   equ 20
BI_RSDP         equ 24
BI_DISK_SIG     equ 28
BI_BOOT_PART    equ 32
BI_CMDLINE_LEN  equ 34
BI_CMDLINE      equ 36
BI_LOG_LEN      equ 292
BI_LOG_PHYS     equ 296
BI_MMAP_LEN     equ 300
BI_MMAP         equ 304
BI_FB_ADDR      equ 1072
BI_FB_WIDTH     equ 1076
BI_FB_HEIGHT    equ 1078
BI_FB_PITCH     equ 1080
BI_FB_BPP       equ 1082
BI_FONT_ADDR    equ 1084
BOOTINFO_SIZE   equ 1088
MEMRANGE_SIZE   equ 24
MAX_MMAP        equ 32

BOOTINFO_MAGIC  equ 0x0EEEB007
BOOTINFO_VER    equ 2

FONT_PHYS       equ 0x5000          ; 4 KiB of 8x16 glyphs, below BootInfo
VBE_INFO        equ 0x0500          ; scratch for the VBE controller block
VBE_MODE_INFO   equ 0x0700          ; scratch for one mode block

; Preferred display size. The target panel is 800x480, which its video BIOS
; does not offer as a VBE mode, so the search falls back by area and this is
; an aspiration rather than a requirement.
WANT_WIDTH      equ 800
WANT_HEIGHT     equ 480

; ---------------------------------------------------------------------------
; Header. mkimage locates this by signature and patches the fields.
; ---------------------------------------------------------------------------
entry:
    jmp short main
    nop
header:
    db "VIBEEE2!"                   ; signature mkimage searches for
kernel_lba:      dd 0               ; PATCHED: first LBA of the kernel image
kernel_sectors:  dd 0               ; PATCHED: kernel size in 512-byte sectors
kernel_bytes:    dd 0               ; PATCHED: exact kernel byte length
cmdline:         times 64 db 0      ; PATCHED: boot parameters, NUL-terminated
rootfs_lba:      dd 0               ; PATCHED: first LBA of the root filesystem
rootfs_sectors:  dd 0               ; PATCHED: root filesystem size in sectors
rootfs_bytes:    dd 0               ; PATCHED: exact root filesystem byte length

main:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00                  ; reuse stage1's stack region
    cld
    sti

    mov [boot_drive], dl

    mov si, msg_banner
    call print

    call enable_a20
    jc  .a20_failed

    call zero_bootinfo
    call collect_e820
    call find_rsdp
    call load_kernel
    call load_rootfs
    call copy_font
    call maybe_set_video
    call finish_bootinfo

    mov si, msg_entering
    call print

    jmp enter_protected_mode

.a20_failed:
    mov si, msg_a20
    jmp fatal

; ---------------------------------------------------------------------------
; A20. Try the BIOS service first, then the fast gate at port 0x92, verifying
; after each attempt, some BIOSes report success without actually enabling it.
; ---------------------------------------------------------------------------
enable_a20:
    call test_a20
    jnc .done                       ; already on (common after a warm boot)

    mov ax, 0x2401                  ; BIOS: enable A20
    int 0x15
    call test_a20
    jnc .done

    in  al, 0x92                    ; fast A20 gate
    test al, 2
    jnz .skip_92                    ; already set; writing again can reset
    or  al, 2
    and al, 0xFE                    ; never touch bit 0, it is a fast reset
    out 0x92, al
.skip_92:
    call test_a20
.done:
    ret

; Write two values 1 MiB apart and see whether they alias.
; CF clear = A20 enabled.
test_a20:
    push ds
    push es
    push si
    push di

    xor ax, ax
    mov ds, ax
    mov si, 0x0500
    mov ax, 0xFFFF
    mov es, ax
    mov di, 0x0510                  ; 0xFFFF:0x0510 = 0x100500 -> aliases 0x0500

    mov al, [ds:si]
    push ax
    mov al, [es:di]
    push ax

    mov byte [ds:si], 0x00
    mov byte [es:di], 0xFF
    mov al, [ds:si]
    cmp al, 0xFF                    ; if it changed too, the address wrapped
    mov bx, 0                       ; (clobbers nothing we need)

    pop ax
    mov [es:di], al
    pop ax
    mov [ds:si], al

    pop di
    pop si
    pop es
    pop ds

    je .disabled
    clc
    ret
.disabled:
    stc
    ret

; ---------------------------------------------------------------------------
; BootInfo
; ---------------------------------------------------------------------------
zero_bootinfo:
    push es
    mov ax, 0
    mov es, ax
    mov di, BOOTINFO_ADDR
    mov cx, BOOTINFO_SIZE / 2
    xor ax, ax
    rep stosw
    pop es

    mov dword [BOOTINFO_ADDR + BI_MAGIC], BOOTINFO_MAGIC
    mov word  [BOOTINFO_ADDR + BI_VERSION], BOOTINFO_VER
    mov word  [BOOTINFO_ADDR + BI_SOURCE], 0        ; 0 = stage2
    ret

finish_bootinfo:
    ; Copy the boot parameters mkimage patched into our header.
    push ds
    push es
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov si, cmdline
    mov di, BOOTINFO_ADDR + BI_CMDLINE
    xor cx, cx
.cmd_copy:
    lodsb
    test al, al
    jz .cmd_done
    stosb
    inc cx
    cmp cx, 63
    jb .cmd_copy
.cmd_done:
    mov [BOOTINFO_ADDR + BI_CMDLINE_LEN], cx
    pop es
    pop ds

    mov dword [BOOTINFO_ADDR + BI_KERNEL_PHYS], KERNEL_PHYS
    mov eax, [kernel_bytes]
    mov [BOOTINFO_ADDR + BI_KERNEL_LEN], eax

    mov eax, [rootfs_bytes]
    test eax, eax
    jz .no_rootfs
    mov dword [BOOTINFO_ADDR + BI_ROOTFS_PHYS], ROOTFS_PHYS
    mov [BOOTINFO_ADDR + BI_ROOTFS_LEN], eax
.no_rootfs:
    xor eax, eax
    mov al, [boot_drive]
    mov [BOOTINFO_ADDR + BI_DISK_SIG], eax          ; refined once we read the MBR
    ret

; ---------------------------------------------------------------------------
; Copy the video ROM's 8x16 font somewhere the kernel can reach.
;
; INT 10h AX=1130 BH=06 returns a pointer to the BIOS's own character bitmaps.
; Using them rather than embedding a font costs nothing and matches what the
; machine displays natively. Must happen before any mode change, while the
; video BIOS still has its text-mode state.
; ---------------------------------------------------------------------------
copy_font:
    push es
    push bp

    mov ax, 0x1130
    mov bh, 0x06                    ; 8x16 font
    int 0x10                        ; -> ES:BP

    ; ES:BP -> flat source. 256 glyphs * 16 bytes.
    mov ax, es
    mov ds, ax
    mov si, bp
    xor ax, ax
    mov es, ax
    mov di, FONT_PHYS
    mov cx, 4096 / 2
    rep movsw

    xor ax, ax
    mov ds, ax
    mov dword [BOOTINFO_ADDR + BI_FONT_ADDR], FONT_PHYS

    pop bp
    pop es
    ret

; ---------------------------------------------------------------------------
; Set a linear-framebuffer VBE mode, if one was asked for and one exists.
;
; Gated on "fb" appearing in the command line. Switching to graphics silences
; the text console, so on a machine whose only output is the screen the default
; has to be the mode that is already known to work.
; ---------------------------------------------------------------------------
maybe_set_video:
    ; Look for "fb" in the command line.
    mov si, cmdline
.scan:
    mov al, [si]
    test al, al
    jz .done                        ; end of string, not requested
    cmp al, 'f'
    jne .next
    cmp byte [si + 1], 'b'
    je .requested
.next:
    inc si
    jmp .scan
.done:
    ret

.requested:
    call vbe_setup
    ret

vbe_setup:
    push es

    ; --- controller info ---
    xor ax, ax
    mov es, ax
    mov di, VBE_INFO
    mov dword [es:di], 'VBE2'       ; ask for VBE 2+ information
    mov ax, 0x4F00
    int 0x10
    cmp ax, 0x004F
    jne .fail

    ; Mode list pointer is a real-mode far pointer at offset 14.
    mov si, [VBE_INFO + 14]
    mov ax, [VBE_INFO + 16]
    mov fs, ax                      ; FS:SI walks the mode list

    xor ebx, ebx                    ; best mode area so far
    xor edx, edx                    ; best mode number (in DX)

.next_mode:
    mov cx, [fs:si]
    add si, 2
    cmp cx, 0xFFFF
    je .have_best

    ; --- mode info ---
    push cx
    xor ax, ax
    mov es, ax
    mov di, VBE_MODE_INFO
    mov ax, 0x4F01
    int 0x10
    pop cx
    cmp ax, 0x004F
    jne .next_mode

    ; Require: supported, graphics, and a linear framebuffer.
    mov ax, [VBE_MODE_INFO]         ; mode attributes
    test ax, 0x0001                 ; supported in hardware
    jz .next_mode
    test ax, 0x0010                 ; graphics rather than text
    jz .next_mode
    test ax, 0x0080                 ; linear framebuffer available
    jz .next_mode

    ; 32bpp only. Mixing depths would mean the console handling several pixel
    ; formats before anything can be seen at all.
    cmp byte [VBE_MODE_INFO + 25], 32
    jne .next_mode

    ; Score by area, capped at the preferred size: the largest mode that is no
    ; bigger than the panel.
    movzx eax, word [VBE_MODE_INFO + 18]    ; width
    cmp ax, WANT_WIDTH
    ja .next_mode
    movzx ebp, word [VBE_MODE_INFO + 20]    ; height
    cmp bp, WANT_HEIGHT
    ja .next_mode
    imul eax, ebp
    cmp eax, ebx
    jbe .next_mode

    mov ebx, eax
    mov dx, cx
    jmp .next_mode

.have_best:
    test dx, dx
    jz .fail                        ; nothing suitable

    ; Re-read the winning mode so its geometry can be recorded.
    push dx
    xor ax, ax
    mov es, ax
    mov di, VBE_MODE_INFO
    mov cx, dx
    mov ax, 0x4F01
    int 0x10
    pop dx
    cmp ax, 0x004F
    jne .fail

    ; --- set it, with bit 14 asking for the linear framebuffer ---
    mov bx, dx
    or bx, 0x4000
    mov ax, 0x4F02
    int 0x10
    cmp ax, 0x004F
    jne .fail

    mov eax, [VBE_MODE_INFO + 40]   ; physical framebuffer base
    mov [BOOTINFO_ADDR + BI_FB_ADDR], eax
    mov ax, [VBE_MODE_INFO + 18]
    mov [BOOTINFO_ADDR + BI_FB_WIDTH], ax
    mov ax, [VBE_MODE_INFO + 20]
    mov [BOOTINFO_ADDR + BI_FB_HEIGHT], ax
    mov ax, [VBE_MODE_INFO + 16]    ; bytes per scanline
    mov [BOOTINFO_ADDR + BI_FB_PITCH], ax
    mov al, [VBE_MODE_INFO + 25]
    mov [BOOTINFO_ADDR + BI_FB_BPP], al

.fail:
    pop es
    ret

; ---------------------------------------------------------------------------
; E820 memory map -> BootInfo.mmap
; ---------------------------------------------------------------------------
collect_e820:
    xor ebx, ebx                    ; continuation value
    mov di, BI_MMAP                 ; running offset into BootInfo
    xor si, si                      ; entry count

.next:
    cmp si, MAX_MMAP
    jae .done

    push di
    mov di, E820_BUF
    mov eax, 0xE820
    mov edx, 0x534D4150             ; 'SMAP'
    mov ecx, 24
    mov dword [E820_BUF + 20], 1    ; ACPI 3.0 extended attribute: valid
    int 0x15
    pop di
    jc  .done                       ; CF on the first call means unsupported
    cmp eax, 0x534D4150
    jne .done

    ; Skip zero-length entries, and entries the ACPI 3.0 attribute marks invalid.
    mov eax, [E820_BUF + 8]
    or  eax, [E820_BUF + 12]
    jz  .skip
    test byte [E820_BUF + 20], 1
    jz  .skip

    ; Copy base(8) + len(8) + type(4) into the BootInfo entry.
    push di
    push si
    mov si, E820_BUF
    mov cx, 20 / 2
    push ds
    push es
    mov ax, 0
    mov es, ax
    add di, BOOTINFO_ADDR
    rep movsw
    pop es
    pop ds
    pop si
    pop di

    add di, MEMRANGE_SIZE
    inc si

.skip:
    test ebx, ebx                   ; zero continuation = last entry
    jnz .next

.done:
    mov [BOOTINFO_ADDR + BI_MMAP_LEN], si
    mov word [BOOTINFO_ADDR + BI_MMAP_LEN + 2], 0
    ret

; ---------------------------------------------------------------------------
; ACPI RSDP: first kilobyte of the EBDA, then the BIOS ROM area.
; ---------------------------------------------------------------------------
find_rsdp:
    push es

    mov ax, [0x040E]                ; EBDA segment
    test ax, ax
    jz .rom
    mov es, ax
    xor di, di
    mov cx, 1024 / 16
    call scan_rsdp
    jnc .found

    ; 0xE0000-0xFFFFF, scanned as two 64 KiB segments: DI is 16-bit, so a
    ; single 128 KiB sweep would wrap rather than reach the top of the range,
    ; which is exactly where the RSDP usually lives.
.rom:
    mov ax, 0xE000
    mov es, ax
    xor di, di
    mov cx, 0x10000 / 16
    call scan_rsdp
    jnc .found

    mov ax, 0xF000
    mov es, ax
    xor di, di
    mov cx, 0x10000 / 16
    call scan_rsdp
    jnc .found

    pop es
    ret

.found:
    ; ES:DI -> linear address
    xor eax, eax
    mov ax, es
    shl eax, 4
    xor ebx, ebx
    mov bx, di
    add eax, ebx
    mov [BOOTINFO_ADDR + BI_RSDP], eax
    pop es
    ret

; Scan CX paragraphs from ES:DI for "RSD PTR " with a valid checksum.
; CF clear + ES:DI updated on success.
scan_rsdp:
.loop:
    push cx
    push di
    mov si, rsdp_sig
    mov cx, 8
    repe cmpsb
    pop di
    pop cx
    jne .advance

    ; Verify the ACPI 1.0 checksum, the signature alone appears in unrelated
    ; data often enough to matter.
    push cx
    push di
    xor ax, ax
    mov cx, 20
.sum:
    add al, [es:di]
    inc di
    loop .sum
    pop di
    pop cx
    test al, al
    jnz .advance

    clc
    ret

.advance:
    add di, 16
    loop .loop
    stc
    ret

rsdp_sig: db "RSD PTR "

; ---------------------------------------------------------------------------
; Kernel load: read CHUNK_SECTORS at a time into a low buffer, then copy up
; past 1 MiB through a flat ES (unreal mode).
; ---------------------------------------------------------------------------
load_kernel:
    mov eax, [kernel_lba]
    mov ecx, [kernel_sectors]
    mov edi, KERNEL_PHYS
    jmp load_blob

; ---------------------------------------------------------------------------
; The root filesystem, loaded into RAM.
;
; This is not an optimisation. On the target machine the SD card sits behind a
; USB card reader, and the BIOS can only reach it in real mode: the moment the
; kernel enters protected mode, the medium it booted from becomes unreadable
; until a USB stack exists. Everything needed to reach a shell therefore has to
; be in RAM before that transition.
; ---------------------------------------------------------------------------
load_rootfs:
    mov ecx, [rootfs_sectors]
    test ecx, ecx
    jz .none                        ; no rootfs packed into this image
    mov eax, [rootfs_lba]
    mov edi, ROOTFS_PHYS
    jmp load_blob
.none:
    ret

; ---------------------------------------------------------------------------
; Read ECX sectors starting at LBA EAX to physical address EDI.
;
; Reads land in a low staging buffer first because INT 13h cannot write above
; 1 MiB, then are copied up through a flat ES.
; ---------------------------------------------------------------------------
load_blob:
    mov [dap_lba], eax

.chunk:
    test ecx, ecx
    jz .done

    mov eax, ecx
    cmp eax, CHUNK_SECTORS
    jbe .have_count
    mov eax, CHUNK_SECTORS
.have_count:
    mov [chunk_count], ax
    mov [dap_count], ax

    ; --- read into the staging buffer ---
    push ecx
    push edi
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    pop edi
    pop ecx
    jc .read_error

    ; --- copy staging buffer -> high memory ---
    ; Unreal mode must be re-established here, not once before the loop: the
    ; BIOS loads ES during INT 13h, and any real-mode segment load reloads the
    ; descriptor cache with a 64 KiB limit. Without this the copy below would
    ; silently go nowhere, because EDI is past 1 MiB.
    xor ax, ax
    mov ds, ax
    call setup_unreal

    ; DS:ESI addresses the buffer (segment 0x2000, offset 0); ES is flat, so
    ; EDI is a linear address. a32 makes rep movsd use ESI/EDI/ECX.
    push ecx
    push ds
    mov ax, LOAD_BUF_SEG
    mov ds, ax
    xor esi, esi
    movzx ecx, word [cs:chunk_count]
    shl ecx, 7                      ; sectors * 512 / 4 = dwords
    a32 rep movsd
    pop ds
    pop ecx

    movzx eax, word [chunk_count]
    sub ecx, eax
    add dword [dap_lba], eax
    jmp .chunk

.done:
    call print_dot
    ret

.read_error:
    mov si, msg_read
    jmp fatal

; Enter protected mode briefly so ES caches a 4 GiB limit, then drop back to
; real mode. The descriptor cache keeps the limit, "unreal mode", which lets
; the copy loop above write above 1 MiB with ordinary real-mode code.
setup_unreal:
    cli
    push ds
    lgdt [gdt_desc]

    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp $+2

    mov bx, 0x10                    ; flat data selector
    mov es, bx

    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp $+2

    pop ds
    sti
    ret

; ---------------------------------------------------------------------------
; Protected mode
; ---------------------------------------------------------------------------
enter_protected_mode:
    cli
    lgdt [gdt_desc]

    mov eax, cr0
    or  eax, 1
    mov cr0, eax
    jmp 0x08:pm_entry

BITS 32
pm_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x7C00

    mov eax, BOOTINFO_MAGIC
    mov ebx, BOOTINFO_ADDR
    jmp KERNEL_PHYS

BITS 16

; ---------------------------------------------------------------------------
; Output helpers (BIOS teletype, the only output we have at this stage)
; ---------------------------------------------------------------------------
print:
    push ax
    push bx
    mov ah, 0x0E
    xor bx, bx
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    pop bx
    pop ax
    ret

print_dot:
    push ax
    push bx
    mov ah, 0x0E
    mov al, '.'
    xor bx, bx
    int 0x10
    pop bx
    pop ax
    ret

fatal:
    call print
    cli
.hang:
    hlt
    jmp .hang

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
align 4
dap:
    db 0x10
    db 0
dap_count:  dw 0
    dw 0                            ; offset 0
    dw LOAD_BUF_SEG
dap_lba:    dq 0

chunk_count: dw 0
boot_drive:  db 0

align 8
gdt:
    dq 0x0000000000000000           ; null
    dq 0x00CF9A000000FFFF           ; 0x08: code, base 0, limit 4 GiB, 32-bit
    dq 0x00CF92000000FFFF           ; 0x10: data, base 0, limit 4 GiB
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

msg_banner:   db "vibeee stage2", 13, 10, 0
msg_entering: db " ok", 13, 10, 0
msg_a20:      db "A20 failed", 13, 10, 0
msg_read:     db "kernel read failed", 13, 10, 0
