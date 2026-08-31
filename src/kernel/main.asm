; MS-DOS64 64-bit kernel entry — stub for Phase 1 scaffold
; Real implementation will replace BIOS far calls with native drivers and flat FCB/DPB structs.
bits 64
default rel

section .text
global _start
_start:
    ; kernel loaded at 0x100000 by stage2
    mov rsp, 0x90000     ; temporary stack in conventional area identity-mapped
    and rsp, ~15         ; 16-byte align for ABI
    call clr_bss
    ; TODO: vga_init, ata_init, rtc_init, fat12_init
    mov rsi, hello
    call vga_print_stub
.hlt:
    cli
    hlt
    jmp .hlt

clr_bss:
    ; bss is zeroed by stage2/loader; placeholder
    ret

vga_print_stub:
    ; stub: write to 0xB8000 direct (will be moved to drivers/vga.asm)
    mov rdi, 0xB8000
    xor rcx, rcx
.loop:
    lodsb
    test al, al
    jz .done
    stosb
    mov al, 0x0F
    stosb
    jmp .loop
.done:
    ret

section .rodata
hello db "Hello from 64-bit DOS64 kernel stub (Phase1) - Phase2 pending", 0

section .bss
align 4096
resb 8192
kstack_top:
