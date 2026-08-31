; GDT definitions for stage2 (32-bit and 64-bit)
; Used by docs/05-boot-and-testing-strategy.md
%ifndef GDT_ASM
%define GDT_ASM

; --- 32-bit GDT ---
gdt32_start:
    dq 0                ; null
    ; code 0x08: base 0, limit 0xFFFFF, 4KB, 32-bit, exec/read, P=1, DPL0, S=1, type A=1
    dw 0xFFFF           ; limit low
    dw 0x0000           ; base low
    db 0x00             ; base mid
    db 0x9A             ; access: P=1, DPL0, S=1, type 1010
    db 0xCF             ; flags: G=1, D=1, limit high F, AVL0
    db 0x00             ; base high
    ; data 0x10: base 0, limit 0xFFFFF, writable
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF
    db 0x00
gdt32_end:
gdt32_ptr:
    dw gdt32_end - gdt32_start - 1
    dd gdt32_start

; --- 64-bit GDT ---
gdt64_start:
    dq 0
    ; 64-bit code 0x08: L=1, D=0, A=1, P=1
    dw 0x0000
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xAF             ; L=1 (bit5 of flags), G=1 — 0xAF = 10101111
    db 0x00
    ; 64-bit data 0x10: writable - L must be 0 for data
    dw 0x0000
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF             ; G=1, D=1, L=0, limit F
    db 0x00
gdt64_end:
gdt64_ptr:
    dw gdt64_end - gdt64_start - 1
    dq gdt64_start

%endif
