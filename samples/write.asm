; WRITE.COM — N2 acceptance sample: args + file write + exit code in one.
;
; Assemble host-side:  nasm -f bin samples/write.asm -o WRITE.COM
; Runs on MS-DOS64 via:  A> WRITE hello   (prints "hello", writes OUT.TXT,
;                                          exits with len => shell "Exit 5")
;
; Proves the whole N2 contract in one program:
;   1. Loaded from the volume BY NAME with args (shell EXEC-from-path).
;   2. Actually RUNS (N2a enter) with RDI=PSP (N2a entry convention).
;   3. Writes a file: 3Ch CREATE + 40h WRITE + 3Eh CLOSE (N2c handles).
;   4. Exits with a code the shell prints (N2d Exit + ERRORLEVEL).
; Follow with:  A> TYPE OUT.TXT   then  A> DEL OUT.TXT   (demo stays clean)
;
; Constraints per docs/21-nasm-cross.md: bits 64, RIP-relative, no `org`
; (load address PSP+PSP_SIZE), real INT 21h handlers only, exit don't RET.

bits 64
default rel

PSP_CMD_LEN equ 0xA0
PSP_CMD_TAIL equ 0xA1

start:
    mov r13, rdi              ; PSP (N2a contract: RDI=PSP on entry)
    test r13, r13
    jz .fail                  ; paranoia: no PSP, no work (exit 1)
    movzx r12d, byte [r13 + PSP_CMD_LEN]   ; R12 = tail len (exit code)
    ; print tail (AH=02h loop) + CRLF (VGA; shell prints stay on serial)
    lea rsi, [r13 + PSP_CMD_TAIL]
    mov ecx, r12d
    test ecx, ecx
    jz .crlf
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
    ; create OUT.TXT, write tail, close (write errors close first: no leaks)
    mov eax, 0x3C00
    lea rdx, [rel fname]
    int 0x21
    jc .fail
    mov rbx, rax              ; fd (preserved across handlers: pushed/popped)
    mov eax, 0x4000
    mov ecx, r12d             ; len (0 ok: zero-write succeeds, empty file)
    lea rdx, [r13 + PSP_CMD_TAIL]
    int 0x21
    jc .failclose
    cmp rax, r12              ; full write or honest failure
    jne .failclose
    mov eax, 0x3E00           ; RBX still fd
    int 0x21
    jc .fail
    ; exit with tail length
    movzx eax, r12b
    mov ah, 0x4C
    int 0x21
.failclose:
    mov eax, 0x3E00           ; RBX still fd: close, then fail (no leak)
    int 0x21
.fail:
    mov eax, 0x4C01
    int 0x21

fname db "OUT.TXT",0
