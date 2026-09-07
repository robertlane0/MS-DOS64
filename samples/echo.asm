; ECHO.COM — echo the PSP command tail (N1 cross-assemble sample).
;
; Assemble host-side:  nasm -f bin samples/echo.asm -o ECHO.COM
; Runs on MS-DOS64 via:  A> ECHO hello world   (prints "hello world")
;
; The shell stores the command tail in PSP64 (+0xA0 len, +0xA1 127 bytes)
; via psp_set_cmdtail64 at spawn. A .COM image is loaded at PSP+PSP_SIZE
; (664, include/psp.inc) with entry = PSP+PSP_SIZE (proc_load_image64),
; so PSP = entry - 664. Derive it from RIP instead of trusting any
; register (N2a pins RDI=PSP as the authoritative entry convention; the
; subtraction holds by construction as fallback).
;
; Uses only: AH=02h conout (DL=char), AH=4Ch exit. Tail is length-prefixed,
; NOT '$'-terminated, so print char-by-char with a CRLF after.

bits 64
default rel

PSP_CMD_LEN equ 0xA0
PSP_CMD_TAIL equ 0xA1
PSP_SIZE equ 664            ; == PSP64_size (proc_load_image64 loads at PSP+PSP_SIZE)

start:
    lea rax, [rel start]   ; RAX = entry = PSP+PSP_SIZE
    sub rax, PSP_SIZE      ; RAX = PSP
    movzx ecx, byte [rax + PSP_CMD_LEN]
    test ecx, ecx
    jz .crlf               ; empty tail: just newline
    lea rsi, [rax + PSP_CMD_TAIL]
.print:
    mov dl, [rsi]
    mov ah, 0x02
    int 0x21
    inc rsi
    dec ecx
    jnz .print
.crlf:
    mov dl, 13
    mov ah, 0x02
    int 0x21
    mov dl, 10
    mov ah, 0x02
    int 0x21
    mov eax, 0x4C00
    int 0x21
