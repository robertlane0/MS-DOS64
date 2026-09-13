; ASM64.COM main (N4B.2 tool): CLI wrapper over the pure asm64_assemble core.
; Usage: ASM64 IN.ASM [-o OUT.COM] [-l OUT.LST] (any flag order; first bare
; arg = input; default output = input basename + ".COM").
; Exit codes: 0 ok, 1 assembly errors, 2 file/usage/limit errors (batch
; %ERRORLEVEL%-safe). Diagnostics `FILE:LINE: message` via AH=09h pieces.
;
; Build: nasm -f elf64 + ld -T src/tools/tools.ld (base 0, _start first) +
; objcopy -O binary + truncate-to-BSS-end (Makefile). NOT -f bin: the core
; carries ~18 KB of BSS that -f bin drops, and NASM cannot express the exact
; back-pad in one pass (circular TIMES). The linked image is slide-safe by
; construction (RIP-relative only, same bar as CHELLO: no relocs/GOT/syscall).
;
; Runtime: entry RDI=PSP (N2a); tail at PSP+0xA0/0xA1. Bulk memory (64 KiB
; source/output/listing) via AH=48h heap; only tiny statics in .data (the
; flat image has no BSS backing, so this file uses NO .bss of its own).
; Child stack is 2048 B: keep frames small, preserve RBX RBP R12-R15.

BITS 64
default rel

global _start
extern asm64_assemble

section .text

; ---- entry (offset 0: tools.ld puts main.o .text first) ----
_start:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15                      ; 6 pushes: (8+48)%16==8...
    sub rsp, 8                    ; ...now RSP%16==0 for calls
    mov [rel psp_save], rdi       ; PSP home (INT traps may clobber volatiles)
    mov qword [rel in_fd], -1
    mov qword [rel out_fd], -1
    mov qword [rel src_ptr], 0
    mov qword [rel out_ptr], 0
    mov qword [rel list_ptr], 0
    call parse_args               ; CF=1 usage error
    jc .usage
    call run_assemble             ; RAX=exit code
    jmp .exit
.usage:
    lea rdx, [rel msg_usage]
    mov eax, 0x0900
    int 0x21
    mov eax, 2
.exit:
    movzx eax, al                 ; code -> AL
    mov ah, 0x4C
    int 0x21                      ; AH=4Ch EXIT (no return)
.hang:
    jmp .hang                     ; paranoia (unreachable)

; parse_args: tokenize PSP tail into in/out/list names (.data, uppercased).
;   CF=1 usage error (caller prints usage, exits 2). Preserves RBX/RBP/R12-R15.
parse_args:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, [rel psp_save]
    movzx ecx, byte [rbx + 0xA0]  ; tail len
    test ecx, ecx
    jz .pa_usage                  ; empty tail
    cmp ecx, 127
    jbe .pa_lenok
    mov ecx, 127
.pa_lenok:
    lea rsi, [rbx + 0xA1]
    lea rdi, [rel tailbuf]
    cld
    rep movsb                     ; copy tail (RCX=0 now)
    mov byte [rdi], 0             ; NUL-terminate
    lea r14, [rel tailbuf]        ; cursor
    xor r13d, r13d                ; have-input flag
.pa_tok:
    mov rdi, r14
    call skip_spaces
    mov r14, rax
    cmp byte [r14], 0
    je .pa_done
    cmp byte [r14], '-'
    je .pa_flag
    ; bare token: the single input (second bare = usage error)
    test r13d, r13d
    jnz .pa_usage
    mov rdi, r14
    lea rsi, [rel in_name]
    call take_token               ; RSI=dst(13B); R14=after; CF=toolong
    jc .pa_usage
    mov r14, rax
    mov r13d, 1
    jmp .pa_tok
.pa_flag:
    inc r14                       ; past '-'
    mov al, [r14]
    or al, 0x20                   ; lowercase flag letter
    cmp al, 'o'
    je .pa_out
    cmp al, 'l'
    je .pa_list
    jmp .pa_usage                 ; unknown flag
.pa_out:
    inc r14
    cmp byte [r14], 0
    je .pa_usage                  ; "-o" glued to EOL: missing value
    cmp byte [r14], ' '
    jne .pa_usage                 ; "-oX": only separate "-o X" supported
    mov rdi, r14
    call skip_spaces
    mov r14, rax
    cmp byte [r14], 0
    je .pa_usage                  ; missing value
    mov rdi, r14
    lea rsi, [rel out_name]
    call take_token
    jc .pa_usage
    mov r14, rax
    jmp .pa_tok
.pa_list:
    inc r14
    cmp byte [r14], 0
    je .pa_usage
    cmp byte [r14], ' '
    jne .pa_usage
    mov rdi, r14
    call skip_spaces
    mov r14, rax
    cmp byte [r14], 0
    je .pa_usage
    mov rdi, r14
    lea rsi, [rel list_name]
    call take_token
    jc .pa_usage
    mov r14, rax
    jmp .pa_tok
.pa_done:
    test r13d, r13d
    jz .pa_usage                  ; no input
    ; default output = input basename + ".COM" (when -o absent)
    cmp byte [rel out_name], 0
    jne .pa_upper
    lea rdi, [rel in_name]
    lea rsi, [rel out_name]
    call default_com              ; CF=malformed
    jc .pa_usage
.pa_upper:
    ; (names already uppercased by take_token)
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.pa_usage:
    stc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; skip_spaces(RDI) -> RAX=past spaces/tabs. Leaf (clobbers RCX).
skip_spaces:
    mov rax, rdi
.ss_loop:
    mov cl, [rax]
    cmp cl, ' '
    je .ss_adv
    cmp cl, 9
    jne .ss_done
.ss_adv:
    inc rax
    jmp .ss_loop
.ss_done:
    ret

; take_token(RDI=src, RSI=dst13) -> RAX=after, CF=1 if >12 chars.
; Copies to space/NUL, uppercases A-Z, NUL-terminates. Preserves RBX.
take_token:
    push rbx
    xor ecx, ecx                  ; len
.tt_loop:
    mov al, [rdi]
    test al, al
    jz .tt_end
    cmp al, ' '
    je .tt_end
    cmp al, 9
    je .tt_end
    cmp ecx, 12
    jae .tt_long
    cmp al, 'a'
    jb .tt_store
    cmp al, 'z'
    ja .tt_store
    sub al, 0x20                  ; uppercase (DOS 8.3 convention)
.tt_store:
    mov [rsi + rcx], al
    inc rdi
    inc rcx
    jmp .tt_loop
.tt_end:
    mov byte [rsi + rcx], 0
    mov rax, rdi
    clc
    pop rbx
    ret
.tt_long:
    stc
    pop rbx
    ret

; default_com(RDI=in "NAME.EXT"/"NAME", RSI=out13): basename + ".COM".
; CF=1 if name part >8 or ext >3 (not 8.3). Preserves RBX.
default_com:
    push rbx
    xor ecx, ecx                  ; name len
.dc_name:
    mov al, [rdi]
    test al, al
    jz .dc_dot
    cmp al, '.'
    je .dc_ext
    cmp ecx, 8
    jae .dc_bad
    mov [rsi + rcx], al
    inc rdi
    inc rcx
    jmp .dc_name
.dc_ext:
    inc rdi                       ; skip '.'
    mov ebx, ecx                  ; name len saved (dot position varies)
    jmp .dc_com
.dc_dot:
    mov ebx, ecx
.dc_com:
    mov byte [rsi + rbx], '.'
    mov byte [rsi + rbx + 1], 'C'
    mov byte [rsi + rbx + 2], 'O'
    mov byte [rsi + rbx + 3], 'M'
    mov byte [rsi + rbx + 4], 0
    clc
    pop rbx
    ret
.dc_bad:
    stc
    pop rbx
    ret

; run_assemble: open/read/assemble/write sequence. -> RAX=exit code
;   (0 ok, 1 asm errors, 2 file/usage/limit). Preserves RBX/RBP/R12-R15.
run_assemble:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                    ; align (6 pushes -> 8; minus 8 -> 0)
    ; alloc source buffer (64 KiB)
    mov edi, 65536
    mov eax, 0x4800
    int 0x21                      ; AH=48h ALLOC, RDI=bytes -> RAX=ptr
    jc .ra_nomem
    mov [rel src_ptr], rax
    ; open input (read-only)
    lea rdx, [rel in_name]
    mov eax, 0x3D00               ; AH=3Dh OPEN, AL=0
    int 0x21
    jc .ra_noopen
    mov [rel in_fd], rax
    ; read loop (32 KiB chunks until short; fd reloaded from in_fd each
    ; use — traps preserve caller regs, but explicit reloads are cheaper
    ; than auditing every handler path)
    xor r13d, r13d                ; total (32-bit: cap 65535)
.ra_read:
    mov rax, [rel in_fd]
    mov rbx, rax
    mov rcx, 32768
    mov rdx, [rel src_ptr]
    add rdx, r13
    mov eax, 0x3F00               ; AH=3Fh READ
    int 0x21
    jc .ra_readerr
    test rax, rax
    jz .ra_eof
    add r13, rax
    cmp r13, 65535
    ja .ra_big
    cmp rax, 32768
    je .ra_read                   ; full chunk: maybe more
.ra_eof:
    ; close input (done with it before CREATE truncates anything)
    mov rax, [rel in_fd]
    mov rbx, rax
    mov eax, 0x3E00
    int 0x21
    mov qword [rel in_fd], -1
    ; alloc output buffer (64 KiB)
    mov edi, 65536
    mov eax, 0x4800
    int 0x21
    jc .ra_nomem
    mov [rel out_ptr], rax
    ; listing buffer only with -l
    cmp byte [rel list_name], 0
    je .ra_no_listbuf
    mov edi, 65536
    mov eax, 0x4800
    int 0x21
    jc .ra_nomem
    mov [rel list_ptr], rax
.ra_no_listbuf:
    ; assemble: (src, srclen, out, 64K, list?, listcap?, err, 256)
    mov rdi, [rel src_ptr]
    mov rsi, r13                  ; srclen
    mov rdx, [rel out_ptr]
    mov rcx, 65536
    mov r8, [rel list_ptr]
    xor r9d, r9d
    test r8, r8
    jz .ra_no_listcap
    mov r9, 65536
.ra_no_listcap:
    push 256                      ; 8th: errcap
    lea rax, [rel errbuf]
    push rax                      ; 7th: err (16 B pushed: still aligned)
    call asm64_assemble
    add rsp, 16
    cmp rax, -1
    je .ra_asmerr
    mov r14, rax                  ; out bytes
    ; create + write output
    lea rdx, [rel out_name]
    xor ecx, ecx
    mov eax, 0x3C00               ; AH=3Ch CREATE
    int 0x21
    jc .ra_nocreate
    mov [rel out_fd], rax
    mov rdi, rax                  ; fd
    mov rsi, [rel out_ptr]
    mov rdx, r14
    call write_all                ; CF=1 write error
    jc .ra_writeerr
    mov rax, [rel out_fd]
    mov rbx, rax
    mov eax, 0x3E00
    int 0x21
    mov qword [rel out_fd], -1
    ; listing file if requested
    cmp byte [rel list_name], 0
    je .ra_no_listfile
    mov rsi, [rel list_ptr]
    call list_len                 ; RCX = bytes to NUL cap... (see below)
    lea rdx, [rel list_name]
    xor ecx, ecx
    mov eax, 0x3C00
    int 0x21
    jc .ra_nocreate_list
    mov [rel out_fd], rax
    mov rdi, rax
    mov rsi, [rel list_ptr]
    mov rdx, [rel list_used]
    call write_all
    jc .ra_writeerr
    mov rax, [rel out_fd]
    mov rbx, rax
    mov eax, 0x3E00
    int 0x21
    mov qword [rel out_fd], -1
.ra_no_listfile:
    ; success: "Assembled N bytes -> OUT$\r\n"
    lea rdx, [rel msg_ok1]
    mov eax, 0x0900
    int 0x21
    mov rax, r14
    lea rdi, [rel numbuf]
    call itoa                     ; NUL string
    lea rsi, [rel numbuf]
    call print_nstr
    lea rdx, [rel msg_ok2]
    mov eax, 0x0900
    int 0x21
    lea rsi, [rel out_name]
    call print_nstr
    lea rsi, [rel msg_crlf]
    call print_nstr
    xor eax, eax                  ; exit 0
    jmp .ra_done
.ra_asmerr:
    ; "INFILE:LINE: msg\r\n" (errbuf already "LINE: msg")
    lea rsi, [rel in_name]
    call print_nstr
    mov dl, ':'
    mov eax, 0x0200
    int 0x21
    lea rsi, [rel errbuf]
    call print_nstr
    lea rsi, [rel msg_crlf]
    call print_nstr
    mov eax, 1
    jmp .ra_done
.ra_noopen:
    lea rdx, [rel msg_noopen]
    mov eax, 0x0900
    int 0x21
    lea rsi, [rel in_name]
    call print_nstr
    lea rsi, [rel msg_crlf]
    call print_nstr
    mov eax, 2
    jmp .ra_done
.ra_big:
    lea rdx, [rel msg_big]
    mov eax, 0x0900
    int 0x21
    mov eax, 2
    jmp .ra_close_in_done
.ra_readerr:
    lea rdx, [rel msg_readerr]
    mov eax, 0x0900
    int 0x21
    mov eax, 2
    jmp .ra_close_in_done
.ra_nomem:
    lea rdx, [rel msg_nomem]
    mov eax, 0x0900
    int 0x21
    mov eax, 2
    jmp .ra_done
.ra_nocreate:
    lea rdx, [rel msg_nocreate]
    mov eax, 0x0900
    int 0x21
    lea rsi, [rel out_name]
    call print_nstr
    lea rsi, [rel msg_crlf]
    call print_nstr
    mov eax, 2
    jmp .ra_done
.ra_nocreate_list:
    lea rdx, [rel msg_nocreate]
    mov eax, 0x0900
    int 0x21
    lea rsi, [rel list_name]
    call print_nstr
    lea rsi, [rel msg_crlf]
    call print_nstr
    mov eax, 2
    jmp .ra_done
.ra_writeerr:
    lea rdx, [rel msg_writeerr]
    mov eax, 0x0900
    int 0x21
    mov eax, 2
    jmp .ra_close_out_done
.ra_close_in_done:
    mov r15, rax                  ; stash code (close clobbers RAX)
    cmp qword [rel in_fd], -1
    je .ra_ci_done
    mov rax, [rel in_fd]
    mov rbx, rax
    mov eax, 0x3E00
    int 0x21
    mov qword [rel in_fd], -1
.ra_ci_done:
    mov rax, r15
    jmp .ra_done
.ra_close_out_done:
    mov r15, rax
    cmp qword [rel out_fd], -1
    je .ra_co_done
    mov rax, [rel out_fd]
    mov rbx, rax
    mov eax, 0x3E00
    int 0x21
    mov qword [rel out_fd], -1
.ra_co_done:
    mov rax, r15
.ra_done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; write_all(RDI=fd, RSI=buf, RDX=len): 40h loop, 32K chunks.
; CF=1 on short/error. Preserves RBX/RBP/R12-R15.
write_all:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi                  ; fd
    mov r13, rsi                  ; cursor
    mov r14, rdx                  ; remaining
.wa_loop:
    test r14, r14
    jz .wa_ok
    mov rcx, 32768
    cmp r14, rcx
    jae .wa_full
    mov rcx, r14
.wa_full:
    mov rbx, r12
    mov rdx, r13
    mov eax, 0x4000               ; AH=40h WRITE
    int 0x21
    jc .wa_fail
    test rax, rax
    jz .wa_fail                   ; zero write: no progress
    add r13, rax
    sub r14, rax
    jmp .wa_loop
.wa_ok:
    clc
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.wa_fail:
    stc
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; list_len: RCX = used bytes in list buffer (to first NUL, cap 65536).
; Stores to list_used. Preserves all but RAX/RCX.
list_len:
    push rsi
    push rdi
    mov rsi, [rel list_ptr]
    mov rdi, rsi
    mov rcx, 65536
.ll_scan:
    cmp byte [rdi], 0
    je .ll_found
    inc rdi
    dec rcx
    jnz .ll_scan
.ll_found:
    sub rdi, rsi                  ; used
    mov [rel list_used], rdi
    mov rcx, rdi
    pop rdi
    pop rsi
    ret

; itoa(RAX=value, RDI=buf): unsigned decimal NUL string. Preserves RBX.
itoa:
    push rbx
    push rdi
    mov rbx, rdi
    sub rsp, 24                   ; digit scratch (misaligns; no calls inside)
    lea rcx, [rsp + 24]           ; end (exclusive)
    test rax, rax
    jnz .it_loop
    dec rcx
    mov byte [rcx], '0'
    jmp .it_copy
.it_loop:
    test rax, rax
    jz .it_copy
    xor edx, edx
    mov r8d, 10
    div r8                        ; RAX=quot, RDX=rem (r8 scratch: volatile ok)
    add dl, '0'
    dec rcx
    mov [rcx], dl
    jmp .it_loop
.it_copy:
    lea rdx, [rsp + 24]
    sub rdx, rcx                  ; len = end - first-digit
    mov rsi, rcx                  ; src = first digit
    mov rdi, rbx                  ; dst = buf
    cld
    mov rcx, rdx
    rep movsb
    mov byte [rdi], 0
    add rsp, 24
    pop rdi
    pop rbx
    ret

; print_nstr(RSI=NUL string): AH=02h char loop. Preserves all but RAX/RDX.
print_nstr:
    push rax
    push rdx
    push rsi
.pn_loop:
    mov dl, [rsi]
    test dl, dl
    jz .pn_done
    mov eax, 0x0200               ; AH=02h CONOUT
    int 0x21
    inc rsi
    jmp .pn_loop
.pn_done:
    pop rsi
    pop rdx
    pop rax
    ret

section .rodata
msg_usage db "Usage: ASM64 IN.ASM [-o OUT.COM] [-l OUT.LST]",13,10,"$"
msg_noopen db "Cannot open input file: $"
msg_big db "Input too large (max 65535 bytes)",13,10,"$"
msg_readerr db "Read error",13,10,"$"
msg_nomem db "Out of memory",13,10,"$"
msg_nocreate db "Cannot create output file: $"
msg_writeerr db "Write error",13,10,"$"
msg_ok1 db "Assembled $"
msg_ok2 db " bytes -> $"

section .data
psp_save: dq 0
in_fd: dq -1
out_fd: dq -1
src_ptr: dq 0
out_ptr: dq 0
list_ptr: dq 0
list_used: dq 0
tailbuf: times 128 db 0
in_name: times 13 db 0
out_name: times 13 db 0
list_name: times 13 db 0
numbuf: times 32 db 0
errbuf: times 256 db 0
msg_crlf: db 13,10,0
