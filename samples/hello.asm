; HELLO.COM — minimal DOS64 program (N1 cross-assemble sample).
;
; Assemble host-side:  nasm -f bin samples/hello.asm -o HELLO.COM
; Runs on MS-DOS64 via:  A> HELLO   (loads HELLO.COM from the FAT12 volume)
;
; Constraints (see docs/21-nasm-cross.md):
;   - bits 64, RIP-relative only, no `org` (load address is PSP+512,
;     not DOS 0x100; `org` would only lie to absolute addresses, and
;     there are none here).
;   - Only real INT 21h handlers: AH=09h print (RDX -> $-string),
;     AH=4Ch exit (AL=code).
;   - Flat, position-independent, < 4096 bytes (shell staging buffer).
;   - Exits; never RETs to the shell (no return address is defined).

bits 64
default rel

start:
    mov ah, 0x09
    lea rdx, [rel msg]
    int 0x21
    mov eax, 0x4C00        ; AH=4Ch EXIT, AL=0
    int 0x21

msg: db 'Hello from DOS64', 13, 10, '$'
