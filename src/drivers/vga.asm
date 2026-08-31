; MS-DOS64 VGA text-mode driver — native 64-bit, replaces BIOS INT 10h
; Framebuffer at 0xB8000, 80x25, 2 bytes per cell (char + attr)
; Ports 0x3D4/0x3D5 for cursor. No BIOS calls. Identity-mapped.
bits 64
default rel

%define VGA_BASE      0xB8000
%define VGA_COLS      80
%define VGA_ROWS      25
%define VGA_SIZE      (VGA_COLS*VGA_ROWS*2)

section .text
global vga_init
global vga_clear
global vga_putc
global vga_print
global vga_set_cursor

; State in .bss
section .bss
vga_row: resb 1
vga_col: resb 1
vga_attr: resb 1

section .text

; vga_init: clear screen, reset cursor, white on black
vga_init:
    push rax
    mov byte [rel vga_attr], 0x0F
    call vga_clear
    xor al, al
    mov [rel vga_row], al
    mov [rel vga_col], al
    call vga_set_cursor
    pop rax
    ret

; vga_clear: fill VGA buffer with spaces
vga_clear:
    push rdi
    push rax
    push rcx
    mov rdi, VGA_BASE
    mov ah, [rel vga_attr]
    mov al, ' '
    mov rcx, VGA_COLS*VGA_ROWS
    rep stosw
    pop rcx
    pop rax
    pop rdi
    ret

; vga_set_cursor: update CRT controller cursor position from vga_row/col
vga_set_cursor:
    push rax
    push rbx
    push rdx
    movzx ax, byte [rel vga_row]
    mov bl, VGA_COLS
    mul bl                  ; AX = row*80
    movzx bx, byte [rel vga_col]
    add ax, bx              ; AX = offset
    mov bx, ax
    mov dx, 0x3D4
    mov al, 0x0E
    out dx, al
    mov dx, 0x3D5
    mov al, bh
    out dx, al
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    mov dx, 0x3D5
    mov al, bl
    out dx, al
    pop rdx
    pop rbx
    pop rax
    ret

; vga_putc: AL = char
vga_putc:
    push rax
    push rbx
    push rdi
    cmp al, 10              ; LF
    je .lf
    cmp al, 13              ; CR
    je .cr
    ; printable
    movzx ebx, byte [rel vga_row]
    imul ebx, VGA_COLS
    movzx edi, byte [rel vga_col]
    add ebx, edi
    shl ebx, 1
    mov rdi, VGA_BASE
    add rdi, rbx
    mov ah, [rel vga_attr]
    mov [rdi], ax
    inc byte [rel vga_col]
    cmp byte [rel vga_col], VGA_COLS
    jb .cursor
    ; wrap
    mov byte [rel vga_col], 0
    inc byte [rel vga_row]
    cmp byte [rel vga_row], VGA_ROWS
    jb .cursor
    call vga_scroll
    jmp .cursor
.lf:
    inc byte [rel vga_row]
    cmp byte [rel vga_row], VGA_ROWS
    jb .lf_done
    call vga_scroll
.lf_done:
    ; fall through to CR
.cr:
    mov byte [rel vga_col], 0
.cursor:
    call vga_set_cursor
    pop rdi
    pop rbx
    pop rax
    ret

; vga_scroll: scroll up one line, clear last line
vga_scroll:
    push rsi
    push rdi
    push rcx
    mov rsi, VGA_BASE + VGA_COLS*2
    mov rdi, VGA_BASE
    mov rcx, (VGA_ROWS-1)*VGA_COLS
    rep movsw
    ; clear last line
    mov rdi, VGA_BASE + (VGA_ROWS-1)*VGA_COLS*2
    mov ah, [rel vga_attr]
    mov al, ' '
    mov rcx, VGA_COLS
    rep stosw
    dec byte [rel vga_row]
    pop rcx
    pop rdi
    pop rsi
    ret

; vga_print: RSI = zero-terminated string
vga_print:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call vga_putc
    jmp .loop
.done:
    pop rsi
    pop rax
    ret
