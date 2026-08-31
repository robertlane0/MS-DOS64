; Phase 2 – Stage 2 loader stub
; Will perform: A20 → GDT32 → protected → EFER.LME → paging → GDT64 → long → jmp kernel
bits 16
org 0x7E00

%include "src/boot/gdt.asm"

stage2_start:
    cli
    ; TODO: real A20 via 0x92 + keyboard, CPUID LM check, build page tables at 0x1000
    ; Placeholder: enter protected then long via gdt.asm
    lgdt [gdt32_ptr]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x08:pmode

bits 32
pmode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    ; TODO: enable PAE, paging, EFER, jmp 64
    jmp $

; 64-bit entry will jmp to 0x100000 (_start)
