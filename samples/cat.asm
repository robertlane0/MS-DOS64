; CAT.COM — copy stdin (handle 0) to stdout (handle 1), N1 sample.
;
; Assemble host-side:  nasm -f bin samples/cat.asm -o CAT.COM
; Runs on MS-DOS64 via:  A> CAT   (copies console input to console output)
;
; Uses only real handle calls: AH=3Fh READ (BX=0 stdin, CX=count low 16,
; RDX=buffer -> RAX=count, 0 = no more data) and AH=40h WRITE (BX=1
; stdout). No 3Ch/3Dh/3Eh/42h needed, so this runs before N2 lands.
; Named-file arguments need 3Dh OPEN (N2 gap); until then this is a
; stdin->stdout pipe demo, not `cat file`.
;
; Note: stdin is the shared PS/2+serial console (handler_kbd_read_ascii,
; non-blocking: CF/short read = no more data). The loop exits on a
; zero-length read instead of spinning.

bits 64
default rel

BUF_LEN equ 128

start:
.loop:
    mov eax, 0x3F00        ; AH=3Fh READ
    mov ebx, 0             ; handle 0 = stdin
    mov ecx, BUF_LEN
    lea rdx, [rel buf]
    int 0x21
    test eax, eax
    jz .done               ; 0 bytes -> done
    mov ecx, eax           ; count read
    mov eax, 0x4000        ; AH=40h WRITE
    mov ebx, 1             ; handle 1 = stdout
    lea rdx, [rel buf]
    int 0x21
    jmp .loop
.done:
    mov eax, 0x4C00
    int 0x21

; Data inside the image (no BSS: `-f bin` BSS placement is a needless
; portability question; 128 bytes of zeros ride in the file and the
; whole image must stay < 4096 bytes for the shell staging buffer).
buf: times BUF_LEN db 0
