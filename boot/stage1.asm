; vibeee stage1: MBR boot sector.
;
; 440 bytes of code, then the partition table. Its whole job is to pull stage2
; off the medium and jump to it; it deliberately knows nothing about
; partitions or filesystems.
;
; EDD (INT 13h AH=42h) only, no CHS fallback. On this machine the boot medium
; is an SD card behind the BIOS's USB-HDD emulation, where CHS geometry is a
; fiction the BIOS invents; LBA sidesteps the whole translation question. Every
; BIOS that can boot USB supports EDD, and the 701's AMI BIOS is proven to by
; GRUB and syslinux. See design/01-boot.md.

BITS 16
ORG 0x7C00

STAGE2_SEG      equ 0x0000
STAGE2_OFF      equ 0x8000      ; stage2 loads at linear 0x8000
STAGE2_LBA      equ 1           ; immediately after this sector
STAGE2_SECTORS  equ 32          ; 16 KiB ceiling; mkimage checks the real size

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00              ; stack grows down, away from our code
    cld
    sti

    mov [boot_drive], dl        ; BIOS hands us the boot drive here

    ; --- confirm EDD is available before relying on it ------------------
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc  .no_edd
    cmp bx, 0xAA55
    jne .no_edd

    ; --- read stage2 ---------------------------------------------------
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc  .disk_error

    mov dl, [boot_drive]        ; stage2 expects the drive number in DL
    jmp STAGE2_SEG:STAGE2_OFF

.no_edd:
    mov si, msg_no_edd
    jmp fail

.disk_error:
    mov si, msg_disk
    ; fall through

; Print SI as a NUL-terminated string via BIOS teletype, then stop.
; Halting rather than rebooting keeps the message on screen, which matters
; because this machine has no serial port to log to.
fail:
    mov ah, 0x0E
    xor bx, bx
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    cli
.hang:
    hlt
    jmp .hang

; Disk Address Packet for INT 13h AH=42h.
align 4
dap:
    db 0x10                     ; packet size
    db 0
    dw STAGE2_SECTORS
    dw STAGE2_OFF
    dw STAGE2_SEG
    dq STAGE2_LBA

boot_drive:  db 0
msg_no_edd:  db "vibeee: BIOS lacks EDD", 0
msg_disk:    db "vibeee: stage2 read failed", 0

; Pad to the partition table. mkimage writes the table and the 0xAA55 signature,
; so the boot sector and the partition layout stay in one place.
times 440 - ($ - $$) db 0
