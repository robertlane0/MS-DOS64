; MS-DOS64 Stage1 MBR — 512 bytes, BIOS entry at 0x7C00
; Implements AGENTS.md Phase 2: A20, INT13h LBA(42h) with CHS(02h) fallback, load stage2 to 0x7E00, far jmp
; Build: nasm -f bin src/boot/mbr.asm -o build/mbr.bin  (must be 512B, last word AA55)
bits 16
org 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [boot_drive], dl            ; BIOS boot drive

    call init_serial

    mov si, msg_mbr
    call print

    call enable_a20
    mov si, msg_a20
    call print

    ; Try INT13h extensions AH=41h
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .use_chs
    cmp bx, 0xAA55
    jne .use_chs
    test cl, 1
    jz .use_chs

    ; LBA path
    mov si, msg_lba
    call print
    call load_lba
    jmp .loaded

.use_chs:
    mov si, msg_chs
    call print
    call load_chs

.loaded:
    mov si, msg_ok
    call print
    ; far jump to stage2 (CS=0)
    jmp 0x0000:0x7E00

; ------------------------------------------------------------
enable_a20:
    push ax
    ; Fast A20 via port 0x92: set bit1 (A20), clear bit0 (reset)
    in al, 0x92
    or al, 2
    and al, 0xFE
    out 0x92, al
    ; KBC fallback (8042)
    call kbc_wait
    mov al, 0xD1
    out 0x64, al
    call kbc_wait
    mov al, 0xDF
    out 0x60, al
    call kbc_wait
    ; Re-assert fast A20, ensure reset bit cleared
    in al, 0x92
    or al, 2
    and al, 0xFE
    out 0x92, al
    pop ax
    ret

kbc_wait:
    in al, 0x64
    test al, 2
    jnz kbc_wait
    ret

; ------------------------------------------------------------
init_serial:
    push ax
    push dx
    mov dx, 0x3F8 + 3
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8 + 0
    mov al, 0x03
    out dx, al
    mov dx, 0x3F8 + 1
    xor al, al
    out dx, al
    mov dx, 0x3F8 + 3
    mov al, 0x03
    out dx, al
    mov dx, 0x3F8 + 2
    xor al, al              ; disable FIFO to avoid Bochs overflow
    out dx, al
    mov dx, 0x3F8 + 4
    mov al, 0x03            ; RTS/DTR only, no loopback
    out dx, al
    pop dx
    pop ax
    ret

print:
    push ax
    push bx
    push dx
    mov ah, 0x0E
    mov bx, 0x0007
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    push ax
.wait_ser:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait_ser
    pop ax
    mov dx, 0x3F8
    out dx, al
    jmp .loop
.done:
    pop dx
    pop bx
    pop ax
    ret

; ------------------------------------------------------------
load_lba:
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jnc .ok
    mov si, msg_disk_err
    call print
    jmp halt
.ok:
    ret

load_chs:
    ; Read stage2 via CHS: LBA1 -> C0 H0 S2, count STAGE2_SECTORS
    ; Assumes SPT=63, HPC=16 (Bochs config cylinders=20 heads=16 spt=63)
    ; For 15 sectors starting at S2 -> fits within track (S2..16)
    xor ax, ax
    mov es, ax
    mov bx, 0x7E00
    mov ah, 0x02
    mov al, STAGE2_SECTORS
    mov ch, 0               ; cylinder low 8
    mov cl, 2               ; sector 2, cyl high 0 in bits 6-7
    mov dh, 0               ; head
    mov dl, [boot_drive]
    int 0x13
    jnc .ok
    mov si, msg_disk_err
    call print
    jmp halt
.ok:
    ret

halt:
    cli
    hlt
    jmp halt

; ------------------------------------------------------------
; Data
boot_drive: db 0

; DAP for LBA extended read — must be in low memory addressable by BIOS
dap:
    db 0x10                 ; size
    db 0                    ; reserved
    dw STAGE2_SECTORS       ; sectors to transfer
    dw 0x7E00               ; offset
    dw 0x0000               ; segment (0000:7E00 = 0x7E00)
    dq 1                    ; LBA start (stage2 at LBA1)

msg_mbr:        db 13,10,"MS-DOS64 MBR boot",13,10,0
msg_a20:        db "A20 enabled",13,10,0
msg_lba:        db "Loading stage2 via LBA...",13,10,0
msg_chs:        db "Loading stage2 via CHS...",13,10,0
msg_ok:         db "Stage2 loaded -> 0x7E00",13,10,0
msg_disk_err:   db "Disk read error! halt",13,10,0

; ------------------------------------------------------------
STAGE2_SECTORS equ 15

; Pad to 510 bytes, then boot signature
times 510-($-$$) db 0
dw 0xAA55
