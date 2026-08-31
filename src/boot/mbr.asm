; Phase 2 – Stage 1 MBR stub (512B)
; Placeholder for Phase 1 scaffold. Will be implemented in Phase 2 per docs/05.
; Real implementation: enable A20, load stage2 via INT13h AH=42h, jmp 0x7E00
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
    ; TODO: real→protected→long is in stage2
    mov si, msg
    mov ah, 0x0E
.loop:
    lodsb
    test al, al
    jz .hang
    int 0x10
    jmp .loop
.hang:
    cli
    hlt
    jmp .hang

msg db "MS-DOS64 MBR stub - Phase2 pending", 13, 10, 0
times 510-($-$$) db 0
dw 0xAA55
