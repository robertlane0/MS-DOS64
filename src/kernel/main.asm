; MS-DOS64 64-bit kernel — Phase 2 long-mode entry at 0x100000
; Implements flat VGA driver (0xB8000) and COM1 serial (0x3F8) for verification.
bits 64
default rel

section .text
global _start
_start:
    mov rsp, 0x90000
    and rsp, ~15
    call init_serial64
    mov rsi, hello
    call vga_print_stub
    mov rsi, hello
    call serial_print64
.hlt:
    cli
    hlt
    jmp .hlt

init_serial64:
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 0x03
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al
    mov dx, 0x3FA
    xor al, al              ; disable FIFO
    out dx, al
    mov dx, 0x3FC
    mov al, 0x03
    out dx, al
    ret

serial_print64:
    push rdx
    push rax
.loop:
    lodsb
    test al, al
    jz .done
    push rax
.wait:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait
    pop rax
    mov dx, 0x3F8
    out dx, al
    jmp .loop
.done:
    pop rax
    pop rdx
    ret

clr_bss:
    ret

vga_print_stub:
    ; Write to VGA text buffer 0xB8000 (identity mapped) + also via serial already
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
hello db "Hello from 64-bit DOS64 kernel: Phase2 long mode OK!", 13, 10, 0

section .bss
align 4096
resb 8192
kstack_top:
