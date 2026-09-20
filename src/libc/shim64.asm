; MS-DOS64 shim64 — hosted-C shims for the NASM port (N4A.2a).
; Freestanding System V AMD64, NASM -f elf64. Links with libc64.asm /
; stdio64.asm (+ crt0 at run time); talks to the kernel EXCLUSIVELY
; through INT 21h traps, same as libc64 (never direct-call kernel code,
; never link kernel objects).
; Rules (same as libc64.asm): 16 B RSP alignment before every CALL,
; callee-saved RBX/RBP/R12-R15 preserved, DF=0 around rep ops, NEVER use
; the red zone (live IRQs share the current stack — always sub rsp / push
; first; user C code must use -mno-red-zone for the same reason).
; Trap discipline (see idt64 int21_entry): set EVERY volatile arg reg
; explicitly per call (stale regs are live inputs to some handlers!);
; afterwards ONLY RAX and CF are meaningful — test CF FIRST with jc/jnc.
; Contents (per docs/25-n4a1-trim.md §3 gap table, "ADD" rows):
;   case-insensitive compare (strcasecmp/strncasecmp), span/search
;   (strcspn/strspn/strsep), numeric conversion (strtol/strtoul + a
;   documented sscanf subset), errno/__errno_location/strerror, getenv
;   (over the crt0 envp block), abort (exit 3), perror (console),
;   remove (FCB AH=29h parse + AH=13h delete — AH=41h is still a stub),
;   time/localtime/gmtime/strftime frozen to the kernel's default epoch
;   (1983-04-01 12:00:00, TIME_EPOCH 418046400 — deterministic output).
; errno numbers match glibc so NASM's error paths read correctly.
; sscanf subset: %d %i %u %x %X %o %s %c %n, '*' suppression, field width,
; h/l length (accepted, ignored), whitespace + literal matching. No %[],
; %f, %p — honest cut (NASM uses one "%d:%d" site; documented).

bits 64
default rel

global strcasecmp
global strncasecmp
global mempcpy
global strcspn
global strspn
global strsep
global strtol
global strtoul
global sscanf
global __errno_location
global strerror
global getenv
global abort
global perror
global remove
global time
global localtime
global gmtime
global strftime
global errno
global memchr
global strpbrk
global atoi
global tolower
global toupper
global isspace
global isdigit
global isalpha
global isalnum
global isxdigit
global iscntrl
global ispunct
global fileno
global _fileno
global __isoc23_strtol
global __isoc23_strtoul
global __isoc23_sscanf
global __isoc99_strtol
global __isoc99_strtoul
global __isoc99_sscanf
global crt_envp                  ; envp block (owned here so the kernel link
                                 ; has it; crt0 fills it via extern)

extern putchar
extern strlen
extern exit
extern memmove                   ; libc64: mempcpy builds on it

%define ERANGE_NO 34
%define EINVAL_NO 22
%define ENOENT_NO 2
%define TIME_EPOCH 418046400     ; 1983-04-01 12:00:00 UTC

section .bss
errno: resd 1
err_unknown_buf: resb 32         ; "Unknown error <n>" rendering
sf_tmp: resb 4                   ; %Y digit scratch (single-threaded: static ok)
crt_envp: resq 33                ; envp[0..31] + NULL (MAX_ENV+1, cf. crt0)

section .rodata
err_EPERM:  db "Operation not permitted",0
err_ENOENT: db "No such file or directory",0
err_EIO:    db "Input/output error",0
err_EBADF:  db "Bad file descriptor",0
err_ENOMEM: db "Out of memory",0
err_EACCES: db "Permission denied",0
err_EEXIST: db "File exists",0
err_EINVAL: db "Invalid argument",0
err_ERANGE: db "Numerical result out of range",0
err_unknown_pre: db "Unknown error ",0

section .data
; struct tm, frozen (see header): 1983-04-01 12:00:00, Friday, yday 90.
; Layout = glibc: sec,min,hour,mday,mon(0-based),year(-1900),wday,yday,isdst.
tm_static: dd 0, 0, 12, 1, 3, 83, 5, 90, 0

section .text

; __errno_location() -> RAX=&errno. Leaf.
__errno_location:
    lea rax, [rel errno]
    ret

; ---- case-insensitive compare ----
; FOLD8: 'A'..'Z' in AL -> +32. Flags clobbered, nothing else.
%macro FOLD8 0
    cmp al, 'A'
    jb %%no
    cmp al, 'Z'
    ja %%no
    add al, 32
%%no:
%endmacro

; strcasecmp(RDI=a, RSI=b) -> -1/0/1 on folded UNSIGNED bytes.
strcasecmp:
.sc_loop:
    mov al, [rdi]
    mov cl, [rsi]
    FOLD8
    xchg al, cl                 ; XCHG preserves flags; fold CL via AL
    FOLD8
    xchg al, cl
    cmp al, cl
    jne .sc_diff
    test al, al
    jz .sc_eq
    inc rdi
    inc rsi
    jmp .sc_loop
.sc_eq:
    xor eax, eax
    ret
.sc_diff:
    mov eax, 1
    ja .sc_done                 ; cmp flags survive jne+mov
    mov rax, -1
.sc_done:
    ret

; strncasecmp(RDI=a, RSI=b, RDX=n) -> -1/0/1. n==0 -> 0.
strncasecmp:
    test rdx, rdx
    jz .sn_eq
.sn_loop:
    mov al, [rdi]
    mov cl, [rsi]
    FOLD8
    xchg al, cl
    FOLD8
    xchg al, cl
    cmp al, cl
    jne .sn_diff
    test al, al
    jz .sn_eq
    inc rdi
    inc rsi
    dec rdx
    jnz .sn_loop
.sn_eq:
    xor eax, eax
    ret
.sn_diff:
    mov eax, 1
    ja .sn_done
    mov rax, -1
.sn_done:
    ret

; mempcpy(RDI=dst, RSI=src, RDX=n) -> RAX=end (dst+n). Overlap-safe
; (via memmove, which preserves RDX: only RAX/RCX/RSI/RDI move).
mempcpy:
    sub rsp, 8                  ; align for the call (entry 8 -> 0)
    call memmove                ; RAX = dst
    lea rax, [rax + rdx]
    add rsp, 8
    ret

; ---- span/search ----
; strcspn(RDI=s, RSI=reject) -> RAX=prefix len with no reject chars.
strcspn:
    push rbx
    xor ebx, ebx                ; index
.cs_next:
    mov al, [rdi + rbx]
    test al, al
    jz .cs_done                 ; NUL ends the span
    mov rdx, rsi
.cs_scan:
    mov cl, [rdx]
    test cl, cl
    jz .cs_adv                  ; not rejected: advance
    cmp al, cl
    je .cs_done                 ; rejected: stop
    inc rdx
    jmp .cs_scan
.cs_adv:
    inc rbx
    jmp .cs_next
.cs_done:
    mov rax, rbx
    pop rbx
    ret

; strspn(RDI=s, RSI=accept) -> RAX=prefix len of only accept chars.
strspn:
    push rbx
    xor ebx, ebx
.sp_next:
    mov al, [rdi + rbx]
    test al, al
    jz .sp_done
    mov rdx, rsi
.sp_scan:
    mov cl, [rdx]
    test cl, cl
    jz .sp_done                 ; absent from accept: stop
    cmp al, cl
    je .sp_adv
    inc rdx
    jmp .sp_scan
.sp_adv:
    inc rbx
    jmp .sp_next
.sp_done:
    mov rax, rbx
    pop rbx
    ret

; strchr_local(RDI=set, RSI=c-low-byte) -> RAX=match/NULL. Leaf local
; (keeps this TU self-sufficient for the host harness).
strchr_local:
.sl_loop:
    mov al, [rdi]
    cmp al, sil
    je .sl_found
    test al, al
    jz .sl_miss
    inc rdi
    jmp .sl_loop
.sl_found:
    mov rax, rdi
    ret
.sl_miss:
    xor eax, eax
    ret

; strsep(RDI=*stringp, RSI=delim) -> RAX=token / NULL.
; Standard: leading delimiters yield empty tokens; *stringp=NULL at end.
; Frame: 4 pushes (32: entry 8 -> 0) around the strchr_local call.
strsep:
    test rdi, rdi
    jz .ss_null
    mov rax, [rdi]              ; *stringp
    test rax, rax
    jz .ss_null
    mov rdx, rax                ; scan cursor
.ss_scan:
    mov cl, [rdx]
    test cl, cl
    jz .ss_end                  ; NUL: last token, *stringp=NULL
    push rax
    push rdx
    push rdi
    push rsi
    mov rdi, rsi                ; delim set
    movzx esi, cl
    call strchr_local
    mov rcx, rax                ; found or NULL (RCX survives the call)
    pop rsi
    pop rdi
    pop rdx
    pop rax
    test rcx, rcx
    jz .ss_adv
    mov byte [rdx], 0           ; terminate token...
    lea rcx, [rdx + 1]
    mov [rdi], rcx              ; ...*stringp = next
    ret                         ; RAX still = token start
.ss_adv:
    inc rdx
    jmp .ss_scan
.ss_end:
    mov qword [rdi], 0
    ret                         ; RAX = token start
.ss_null:
    xor eax, eax
    ret

; ---- numeric conversion ----
; ISSPACE8: ZF=1 iff AL is space \t \n \v \f \r. Destroys AL (callers
; only need ZF; they reload the char when it matters).
%macro ISSPACE8 0
    cmp al, ' '
    je %%yes
    cmp al, 9
    jb %%no
    cmp al, 13
    jbe %%yes
%%no:
    mov al, 1
    test al, al                  ; ZF=0
    jmp %%done
%%yes:
    xor al, al                   ; ZF=1
%%done:
%endmacro

; digitval(CL=char) -> EAX=value, CF=0; else CF=1. Clobbers AX/CX only.
digitval:
    movzx eax, cl
    sub eax, '0'
    cmp eax, 9
    jbe .dv_ok
    or cl, 32                   ; fold to lower
    movzx eax, cl
    sub eax, 'a'
    cmp eax, 25
    ja .dv_bad
    add eax, 10
.dv_ok:
    clc
    ret
.dv_bad:
    stc
    ret

; strto_core(RDI=nptr, RSI=endptr, RDX=base, R8D=signed):
; full strtol/strtoul core. RAX=result; endptr stored unless NULL;
; ERANGE + saturation on overflow; no-digits -> 0 with endptr=nptr.
; Frame: pushes rbx,r12,r13,r14,r15 (40: entry 8 -> 0, aligned for the
; digitval calls); digit phase adds cutlim push + 8 pad (56 total).
; Regs: RBX=cursor, R12=endptr slot, R13D=working base, R14D=signed,
; R15=orig nptr, R8D=neg, R9D=flags(bit0 any, bit1 oflow), R11=cutoff,
; [rsp+8]=cutlim, R10=acc, RDI=digit temp. digitval preserves all of
; these (touches only AX/CX).
strto_core:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                ; cursor
    mov r15, rdi                ; orig nptr
    mov r12, rsi                ; endptr slot (may be NULL)
    mov r13d, edx               ; requested base (0 = auto)
    mov r14d, r8d               ; signed flag
    cmp r13d, 1
    je .tc_inv                  ; base 1 invalid (0=auto, 2..36 ok)
    cmp r13d, 36
    ja .tc_inv
.tc_ws:
    mov al, [rbx]
    ISSPACE8
    jnz .tc_sign
    inc rbx
    jmp .tc_ws
.tc_sign:
    xor r8d, r8d                ; neg = 0
    mov al, [rbx]
    cmp al, '-'
    jne .tc_plus
    inc r8d
    inc rbx
    jmp .tc_pfx
.tc_plus:
    cmp al, '+'
    jne .tc_pfx
    inc rbx
.tc_pfx:
    test r13d, r13d             ; auto detect?
    jnz .tc_explicit
    cmp byte [rbx], '0'
    jne .tc_set10
    mov cl, [rbx + 1]
    or cl, 32
    cmp cl, 'x'
    jne .tc_set8
    mov cl, [rbx + 2]           ; 0x needs a following hex digit...
    call digitval
    jc .tc_set8                 ; ...else the 0 stands as octal
    cmp eax, 15
    ja .tc_set8
    add rbx, 2
    mov r13d, 16
    jmp .tc_acc
.tc_set8:
    mov r13d, 8
    jmp .tc_acc
.tc_set10:
    mov r13d, 10
    jmp .tc_acc
.tc_explicit:
    cmp r13d, 16                ; explicit base 16 takes an 0x prefix
    jne .tc_acc
    cmp byte [rbx], '0'
    jne .tc_acc
    mov cl, [rbx + 1]
    or cl, 32
    cmp cl, 'x'
    jne .tc_acc
    mov cl, [rbx + 2]
    call digitval
    jc .tc_acc
    cmp eax, 15
    ja .tc_acc
    add rbx, 2
.tc_acc:
    mov rax, -1                 ; UMAX default (unsigned)
    test r14d, r14d
    jz .tc_lim
    mov rax, 0x7FFFFFFFFFFFFFFF ; SMAX
    test r8d, r8d
    jz .tc_lim
    mov rax, 0x8000000000000000 ; -LONG_MIN magnitude
.tc_lim:
    xor edx, edx
    div r13                     ; RAX=cutoff, RDX=cutlim (RDX:RAX / r13)
    mov r11, rax
    push rdx                    ; cutlim
    sub rsp, 8                  ; pad (frame 56: aligned for digitval)
    xor r10, r10                ; acc = 0
    xor r9d, r9d                ; flags = 0
.tc_dloop:
    mov cl, [rbx]
    test cl, cl
    jz .tc_wrap
    call digitval
    jc .tc_wrap
    cmp eax, r13d
    jae .tc_wrap                ; digit >= base: stop
    mov edi, eax
    or r9d, 1                   ; any_digits
    test r9d, 2
    jnz .tc_consume             ; already overflowed: consume only
    cmp r10, r11
    ja .tc_oflow
    jb .tc_safe
    cmp rdi, [rsp + 8]          ; acc == cutoff: digit <= cutlim?
    ja .tc_oflow
.tc_safe:
    mov rax, r10
    mul r13                     ; RDX:RAX = acc*base (exact: cutoff-checked)
    add rax, rdi
    mov r10, rax
    jmp .tc_next
.tc_oflow:
    or r9d, 2
.tc_consume:
    inc rbx                     ; consume for endptr
    jmp .tc_dloop
.tc_next:
    inc rbx
    jmp .tc_dloop
.tc_wrap:
    add rsp, 16                 ; drop cutlim + pad
    test r9d, 1
    jz .tc_nodig
    test r12, r12
    jz .tc_noend
    mov [r12], rbx
.tc_noend:
    test r9d, 2
    jnz .tc_sat
    mov rax, r10
    test r14d, r14d             ; signed?
    jz .tc_out
    test r8d, r8d               ; neg?
    jz .tc_out
    neg rax
    jmp .tc_out
.tc_sat:
    mov dword [rel errno], ERANGE_NO
    test r14d, r14d
    jz .tc_satu
    mov rax, 0x7FFFFFFFFFFFFFFF ; LONG_MAX
    test r8d, r8d
    jz .tc_out
    mov rax, 0x8000000000000000 ; LONG_MIN
    jmp .tc_out
.tc_satu:
    mov rax, -1                 ; ULONG_MAX...
    test r8d, r8d
    jz .tc_out
    neg rax                     ; ...negated mod 2^64 (C strtoul rule)
    jmp .tc_out
.tc_nodig:
    test r12, r12
    jz .tc_zero
    mov [r12], r15              ; endptr = original nptr
.tc_zero:
    xor eax, eax
.tc_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.tc_inv:
    mov dword [rel errno], EINVAL_NO
    xor eax, eax
    test r12, r12
    jz .tc_ret
    mov [r12], r15
.tc_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; strtol(RDI=nptr, RSI=endptr, RDX=base) -> RAX.
strtol:
    mov r8d, 1
    jmp strto_core
; strtoul(RDI=nptr, RSI=endptr, RDX=base) -> RAX.
strtoul:
    xor r8d, r8d
    jmp strto_core

; ---- sscanf subset ----
; ss_va_next: local copy of libc64's va_next (that symbol is file-local
; there). R14=index (caller zeroes), R15=spill base, R10=overflow base.
; Out: RAX=value, index incremented. Clobbers RAX/R14 only.
ss_va_next:
    cmp r14, 5
    jae .vn_stack
    mov rax, [r15 + r14*8]
    inc r14
    ret
.vn_stack:
    mov rax, r14
    sub rax, 5
    shl rax, 3
    add rax, r10
    mov rax, [rax]
    inc r14
    ret

; ss_num(RDI=cursor, R8D=base(0=auto), R9D=signed, R11D=width(0=unbounded)):
; scan one integer. Out: RAX=value, RDI=end, CF=0 ok / CF=1 no-digits.
; Clobbers RAX,RCX,RDI,RSI. Preserves R8,R9,R10,R11,R13,R14,R15,RBX,RDX.
; acc lives in R12D and neg in R13D (both callee-saved: pushed here;
; digitval touches only AX/CX so they survive it — EAX itself must NOT
; hold acc across the digitval call).
ss_num:
    push rbx
    push r12
    push r13                    ; 3 pushes: entry 8 -> 0, digitval aligned
    mov rsi, rdi                ; cursor
    mov ebx, r11d               ; width; 0 -> -1 (unbounded)
    test ebx, ebx
    jnz .sn_ws
    dec ebx
    ; skip whitespace
.sn_ws:
    mov al, [rsi]
    ISSPACE8
    jnz .sn_sign
    inc rsi
    jmp .sn_ws
.sn_sign:
    xor r13d, r13d              ; neg
    mov al, [rsi]
    cmp al, '-'
    jne .sn_plus
    inc r13d
    inc rsi
    jmp .sn_base
.sn_plus:
    cmp al, '+'
    jne .sn_base
    inc rsi
.sn_base:
    mov r10d, r8d               ; working base
    test r10d, r10d
    jz .sn_auto
    cmp r10d, 16                ; explicit base 16 takes an 0x prefix
    jne .sn_acc
    cmp byte [rsi], '0'
    jne .sn_acc
    mov al, [rsi + 1]
    or al, 32
    cmp al, 'x'
    jne .sn_acc
    mov cl, [rsi + 2]
    call digitval               ; R12/R13 survive (only AX/CX touched)
    jc .sn_acc
    cmp eax, 15
    ja .sn_acc
    add rsi, 2
    jmp .sn_acc
.sn_auto:
    jne .sn_d10
    mov al, [rsi + 1]
    or al, 32
    cmp al, 'x'
    jne .sn_d8
    mov cl, [rsi + 2]
    call digitval               ; R12/R13 survive (only AX/CX touched)
    jc .sn_d8
    cmp eax, 15
    ja .sn_d8
    add rsi, 2
    mov r10d, 16
    jmp .sn_acc
.sn_d8:
    mov r10d, 8
    jmp .sn_acc
.sn_d10:
    mov r10d, 10
.sn_acc:
    xor r12d, r12d              ; acc (32-bit; overflow wraps mod 2^32)
    xor r11d, r11d              ; digits
.sn_loop:
    cmp ebx, 0
    je .sn_full                 ; bounded width exhausted
    mov cl, [rsi]
    test cl, cl
    jz .sn_end
    call digitval
    jc .sn_end
    cmp eax, r10d
    jae .sn_end
    mov ecx, eax                ; digit
    mov eax, r12d               ; acc
    mul r10d                    ; EDX:EAX = acc*base
    add eax, ecx
    mov r12d, eax
    inc rsi
    inc r11d
    cmp ebx, 0
    jl .sn_loop                 ; unbounded: no decrement
    dec ebx
    jmp .sn_loop
.sn_full:
    test r11d, r11d
    jz .sn_fail
    jmp .sn_store
.sn_end:
    test r11d, r11d
    jz .sn_fail
.sn_store:
    mov eax, r12d
    test r9d, r9d               ; signed?
    jz .sn_out
    test r13d, r13d             ; neg?
    jz .sn_out
    neg eax
.sn_out:
    mov rdi, rsi
    clc
    jmp .sn_ret
.sn_fail:
    stc
.sn_ret:
    pop r13
    pop r12
    pop rbx
    ret

; sscanf(RDI=str, RSI=fmt, ...) -> RAX=assigned (EOF(-1) on early input end).
; Subset: %d %i %u %x %X %o %s %c %n, '*' suppression, width, h/l ignored.
; Frame: 5 pushes (40) + sub 48 (88: entry 8 -> 0, aligned for ss_num).
; Spill [rsp+0..32]: RDX,RCX,R8,R9,stk0; [rsp+40]=input-orig for %n.
; Live: RBX=fmt, R13=input, R12D=assigned, R14/R15/R10 va walker.
sscanf:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov [rsp + 0], rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    mov [rsp + 24], r9
    mov rax, [rsp + 96]         ; stk0 = [E+8] (E = rsp+88 here)
    mov [rsp + 32], rax
    lea r15, [rsp]
    lea r10, [rsp + 104]        ; overall idx>=5 -> E+16 base (see sprintf)
    xor r14d, r14d
    mov r13, rdi                ; input cursor
    mov [rsp + 40], rdi         ; input orig (for %n)
    mov rbx, rsi                ; fmt cursor
    xor r12d, r12d              ; assigned
.ss_loop:
    mov al, [rbx]
    test al, al
    jz .ss_done
    cmp al, ' '
    jbe .ss_ws                  ; fmt whitespace (space \t \n \v \f \r):
    cmp al, '%'
    je .ss_pct
    ; literal: must match (NUL input = input end)
    mov cl, [r13]
    test cl, cl
    jz .ss_input_end
    cmp al, cl
    jne .ss_done                ; literal mismatch: stop
    inc rbx
    inc r13
    jmp .ss_loop
.ss_ws:
    cmp al, ' '
    je .ss_ws2
    cmp al, 9
    jb .ss_loop                 ; not ws in fmt after all: re-dispatch
    cmp al, 13
    ja .ss_loop
.ss_ws2:
    inc rbx                     ; skip fmt ws...
.ss_wsin:
    mov cl, [r13]               ; ...and input ws
    cmp cl, ' '
    je .ss_wsi2
    cmp cl, 9
    jb .ss_loop
    cmp cl, 13
    ja .ss_loop
.ss_wsi2:
    inc r13
    jmp .ss_wsin
.ss_pct:
    inc rbx
    mov al, [rbx]
    test al, al
    jz .ss_done                 ; trailing %: stop
    inc rbx
    cmp al, '%'
    jne .ss_dir
    mov cl, [r13]               ; %%: literal %
    test cl, cl
    jz .ss_input_end
    cmp cl, '%'
    jne .ss_done
    inc r13
    jmp .ss_loop
.ss_dir:
    xor r11d, r11d              ; suppress = 0
    cmp al, '*'
    jne .ss_width
    inc r11d
    mov al, [rbx]
    inc rbx
.ss_width:
    xor ecx, ecx                ; width = 0 (unbounded)
.ss_wd:
    cmp al, '0'
    jb .ss_len
    cmp al, '9'
    ja .ss_len
    imul ecx, ecx, 10
    movzx eax, al
    sub eax, '0'
    add ecx, eax
    mov al, [rbx]
    inc rbx
    jmp .ss_wd
.ss_len:
    cmp al, 'h'
    je .ss_len2
    cmp al, 'l'
    jne .ss_conv
.ss_len2:                        ; length mods accepted, ignored (int slots)
    mov al, [rbx]
    inc rbx
    cmp al, 'h'
    je .ss_len3
    cmp al, 'l'
    jne .ss_conv
.ss_len3:
    mov al, [rbx]
    inc rbx
    jmp .ss_conv
.ss_conv:
    cmp al, 'n'
    je .ss_c_n
    cmp al, 's'
    je .ss_c_s
    cmp al, 'c'
    je .ss_c_c
    cmp al, 'd'
    je .ss_c_d
    cmp al, 'i'
    je .ss_c_i
    cmp al, 'u'
    je .ss_c_u
    cmp al, 'x'
    je .ss_c_x
    cmp al, 'X'
    je .ss_c_x
    cmp al, 'o'
    je .ss_c_o
    jmp .ss_done                 ; unsupported verb: honest stop (documented)
.ss_c_n:
    test r11d, r11d             ; %n with *: no-op
    jnz .ss_loop
    call ss_va_next             ; RAX = int* slot
    mov rcx, r13
    sub rcx, [rsp + 40]         ; consumed chars
    mov [rax], ecx
    jmp .ss_loop
.ss_c_s:
    ; skip ws; NUL input = input end
.ss_cs_ws:
    mov cl, [r13]
    cmp cl, ' '
    je .ss_cs_w2
    cmp cl, 9
    jb .ss_cs_go
    cmp cl, 13
    jbe .ss_cs_w2
    jmp .ss_cs_go
.ss_cs_w2:
    inc r13
    jmp .ss_cs_ws
.ss_cs_go:
    test cl, cl
    jz .ss_input_end
    test r11d, r11d
    jnz .ss_cs_sup
    call ss_va_next
    mov rdx, rax                ; dst
    jmp .ss_cs_copy
.ss_cs_sup:
    xor edx, edx                ; suppressed: no store
.ss_cs_copy:
    mov r8d, ecx                ; width (0 = unbounded)
    test r8d, r8d
    jnz .ss_cs_wd
    dec r8d                     ; -> -1 unbounded
    jmp .ss_cs_lp
.ss_cs_wd:
    nop                         ; (width in R8D)
.ss_cs_lp:
    cmp r8d, 0
    je .ss_cs_end
    mov cl, [r13]
    test cl, cl
    jz .ss_cs_end
    cmp cl, ' '
    je .ss_cs_end
    cmp cl, 9
    jb .ss_cs_put
    cmp cl, 13
    jbe .ss_cs_end
.ss_cs_put:
    test rdx, rdx
    jz .ss_cs_nost
    mov [rdx], cl
    inc rdx
.ss_cs_nost:
    inc r13
    cmp r8d, 0
    jl .ss_cs_lp
    dec r8d
    jmp .ss_cs_lp
.ss_cs_end:
    test rdx, rdx
    jz .ss_loop                 ; suppressed: no assign, no NUL
    mov byte [rdx], 0
    inc r12d
    jmp .ss_loop
.ss_c_c:
    mov r8d, ecx                ; width (0 -> default 1 below)
    test r8d, r8d
    jnz .ss_cc_go
    inc r8d
.ss_cc_go:
    test r11d, r11d
    jnz .ss_cc_sup
    call ss_va_next
    mov rdx, rax
    jmp .ss_cc_lp
.ss_cc_sup:
    xor edx, edx
.ss_cc_lp:
    cmp r8d, 0
    je .ss_cc_end
    mov cl, [r13]               ; %c takes NUL too? No: NUL = input end
    test cl, cl
    jz .ss_input_end
    test rdx, rdx
    jz .ss_cc_nost
    mov [rdx], cl
    inc rdx
.ss_cc_nost:
    inc r13
    dec r8d
    jmp .ss_cc_lp
.ss_cc_end:
    test r11d, r11d
    jnz .ss_loop
    inc r12d
    jmp .ss_loop
.ss_c_d:
    mov r8d, 10
    mov r9d, 1
    jmp .ss_num_go
.ss_c_i:
    xor r8d, r8d                ; auto
    mov r9d, 1
    jmp .ss_num_go
.ss_c_u:
    mov r8d, 10
    xor r9d, r9d
    jmp .ss_num_go
.ss_c_x:
    mov r8d, 16
    xor r9d, r9d
    jmp .ss_num_go
.ss_c_o:
    mov r8d, 8
    xor r9d, r9d
.ss_num_go:
    mov ebp, r11d               ; suppress (RBP survives ss_num)
    mov r11d, ecx               ; width
    mov rdi, r13
    call ss_num                 ; (aligned: frame rsp≡0)
    jc .ss_input_end            ; no digits: matching failure
    mov r13, rdi                ; advance input
    mov edx, eax                ; value (ss_num returns 32-bit in EAX)
    test ebp, ebp
    jnz .ss_loop                ; suppressed: no store, no count
    call ss_va_next             ; RAX = int* slot
    mov [rax], edx
    inc r12d
    jmp .ss_loop
.ss_done:
    mov rax, r12
    jmp .ss_ret
.ss_input_end:
    test r12d, r12d
    jnz .ss_done                ; conversions done: return count
    mov rax, -1                 ; none yet: EOF
.ss_ret:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ---- errno / strerror ----
; strerror(RDI=errnum) -> RAX=message. Unknown codes render into a static
; buffer ("Unknown error <n>"). Leaf (no calls).
strerror:
    cmp edi, 1
    jne .se_2
    lea rax, [rel err_EPERM]
    ret
.se_2:
    cmp edi, 2
    jne .se_5
    lea rax, [rel err_ENOENT]
    ret
.se_5:
    cmp edi, 5
    jne .se_9
    lea rax, [rel err_EIO]
    ret
.se_9:
    cmp edi, 9
    jne .se_12
    lea rax, [rel err_EBADF]
    ret
.se_12:
    cmp edi, 12
    jne .se_13
    lea rax, [rel err_ENOMEM]
    ret
.se_13:
    cmp edi, 13
    jne .se_17
    lea rax, [rel err_EACCES]
    ret
.se_17:
    cmp edi, 17
    jne .se_22
    lea rax, [rel err_EEXIST]
    ret
.se_22:
    cmp edi, 22
    jne .se_34
    lea rax, [rel err_EINVAL]
    ret
.se_34:
    cmp edi, 34
    jne .se_unknown
    lea rax, [rel err_ERANGE]
    ret
.se_unknown:
    push rbx                    ; 1 push (entry 8 -> 0; no calls inside)
    mov ebx, edi                ; errnum (unsigned render)
    lea rsi, [rel err_unknown_pre]
    lea rdi, [rel err_unknown_buf]
.se_cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .se_cp
    dec rdi                     ; overwrite the NUL
    mov rax, rbx
    mov ecx, 10                 ; decimal digits, reversed via stack count
    sub rsp, 32                 ; digit scratch (aligned: 8+8+32=48≡0? entry
                                ; 8 + push 8 + sub 32 = 48: rsp≡8-0... 48%16=0
                                ; so rsp≡8: NO CALLS below, safe anyway)
    xor r8d, r8d                ; ndigits
.se_div:
    xor edx, edx
    div rcx
    add dl, '0'
    mov [rsp + r8], dl
    inc r8
    test rax, rax
    jnz .se_div
.se_out:
    dec r8
    js .se_nul
    mov al, [rsp + r8]
    mov [rdi], al
    inc rdi
    jmp .se_out
.se_nul:
    mov byte [rdi], 0
    add rsp, 32
    lea rax, [rel err_unknown_buf]
    pop rbx
    ret

; ---- getenv ----
; getenv(RDI=name) -> RAX=value / NULL. Scans the crt0 envp block
; (NULL-terminated argv-style array of "NAME=VAL"). Leaf.
getenv:
    test rdi, rdi
    jz .ge_null
    lea rdx, [rel crt_envp]
.ge_loop:
    mov rax, [rdx]              ; entry
    test rax, rax
    jz .ge_null
    mov rsi, rdi                ; name cursor
    mov rcx, rax                ; entry cursor
.ge_cmp:
    mov al, [rsi]
    test al, al
    jz .ge_eq                   ; name exhausted: need '=' next
    cmp al, [rcx]
    jne .ge_next
    inc rsi
    inc rcx
    jmp .ge_cmp
.ge_eq:
    cmp byte [rcx], '='
    jne .ge_next
    lea rax, [rcx + 1]
    ret
.ge_next:
    add rdx, 8
    jmp .ge_loop
.ge_null:
    xor eax, eax
    ret

; abort() -> exit(3). Tail call (no frame).
abort:
    mov edi, 3
    jmp exit

; perror(RDI=s) — print "s: <strerror(errno)>\n" on the console (both
; console handles share the VGA path, so no stderr distinction exists).
; Frame: push rbx (8) + sub 16 (24: entry 8 -> 0, aligned for calls).
perror:
    push rbx
    sub rsp, 16
    mov rbx, rdi                ; path (may be NULL)
    test rbx, rbx
    jz .pe_msg
    mov rdi, rbx
    call strlen
    test rax, rax
    jz .pe_msg
.pe_path:
    mov al, [rbx]
    test al, al
    jz .pe_colon
    movzx edi, al
    call putchar
    inc rbx
    jmp .pe_path
.pe_colon:
    mov edi, ':'
    call putchar
    mov edi, ' '
    call putchar
.pe_msg:
    mov edi, [rel errno]
    call strerror               ; RAX = message
    mov rbx, rax
.pe_mloop:
    mov al, [rbx]
    test al, al
    jz .pe_nl
    movzx edi, al
    call putchar
    inc rbx
    jmp .pe_mloop
.pe_nl:
    mov edi, 10
    call putchar
    add rsp, 16
    pop rbx
    ret

; remove(RDI=path) -> RAX=0 / -1 (errno: EINVAL on unparseable/wildcard
; path, ENOENT when the delete misses). FCB AH=29h parse (AL=1: skip
; leading separators) + AH=13h delete. Wildcards are refused: glibc
; remove() has no glob semantics and 13h would delete a set.
; Frame: 3 pushes (24) + sub 80 (104: entry 8 -> 0, aligned); the 80 B
; stack slot is the zeroed FCB.
remove:
    push rbx
    push r12
    push r13
    sub rsp, 80
    test rdi, rdi
    jz .rm_inval
    mov r12, rdi                ; path
    mov rsi, rdi
.rm_scan:
    mov al, [rsi]
    test al, al
    jz .rm_parse
    cmp al, '*'
    je .rm_inval
    cmp al, '?'
    je .rm_inval
    inc rsi
    jmp .rm_scan
.rm_parse:
    lea rdi, [rsp]              ; FCB dst (RSP≡0 here: aligned enough)
    mov rcx, 10
    xor eax, eax
    cld
    rep stosq                   ; zero 80 B
    mov rdx, r12                ; RSI below; stage path in RSI via RDX
    mov rsi, rdx
    lea rdi, [rsp]
    xor ebx, ebx
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x2901             ; AH=29h parse, AL=1 skip separators
    int 0x21
    jc .rm_inval                ; CF first: RAX meaningless on failure
    lea rdx, [rsp]              ; RDX = FCB
    xor ebx, ebx
    xor ecx, ecx
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x1300             ; AH=13h delete
    int 0x21
    jc .rm_noent
    xor eax, eax
    jmp .rm_ret
.rm_noent:
    mov dword [rel errno], ENOENT_NO
    mov rax, -1
    jmp .rm_ret
.rm_inval:
    mov dword [rel errno], EINVAL_NO
    mov rax, -1
.rm_ret:
    add rsp, 80
    pop r13
    pop r12
    pop rbx
    ret

; ---- frozen time ----
; time(RDI=tloc) -> RAX=TIME_EPOCH, stored if tloc != NULL. Leaf.
time:
    mov rax, TIME_EPOCH
    test rdi, rdi
    jz .tm_ret
    mov [rdi], rax
.tm_ret:
    ret
; localtime/gmtime(RDI=timer, ignored) -> RAX=&tm_static. Leaf.
localtime:
    lea rax, [rel tm_static]
    ret
gmtime:
    lea rax, [rel tm_static]
    ret

; PUT2(val-EAX 0..99): store 2 zero-padded digits at [R10], advance R10.
; Clobbers EAX, ECX, EDX. Caller bounds-checks before invoking.
%macro PUT2 0
    mov ecx, 10
    xor edx, edx
    div ecx                     ; EAX=tens, EDX=ones
    add eax, '0'
    mov [r10], al
    mov eax, edx
    add eax, '0'
    mov [r10 + 1], al
    add r10, 2
%endmacro

; strftime(RDI=s, RSI=max, RDX=fmt, RCX=tm) -> RAX=chars (excl NUL) / 0.
; Verbs: %Y %m %d %H %M %S %% (all NASM uses); anything else copies
; through literally as "%<c>". Leaf (no calls).
; Live: RBX=fmt, R12=tm, R13=written, R10=dst(=RDI cursor), RSI=max.
strftime:
    test rsi, rsi
    jz .sf_zero                 ; max==0: nothing (C99)
    push rbx
    push r12
    push r13                    ; 3 pushes (entry 8 -> 0; no calls inside)
    mov r10, rdi
    mov rbx, rdx
    mov r12, rcx
    xor r13d, r13d
.sf_loop:
    mov al, [rbx]
    test al, al
    jz .sf_end
    inc rbx
    cmp al, '%'
    je .sf_verb
    call .sf_emit               ; local near call (aligned: 3 pushes, no
    jmp .sf_loop                ; further stack use — rsp≡0 throughout)
.sf_verb:
    mov al, [rbx]
    test al, al
    jz .sf_end                  ; trailing %: stop
    inc rbx
    cmp al, '%'
    je .sf_lit
    cmp al, 'Y'
    je .sf_Y
    cmp al, 'm'
    je .sf_mon
    cmp al, 'd'
    je .sf_mday
    cmp al, 'H'
    je .sf_hour
    cmp al, 'M'
    je .sf_min
    cmp al, 'S'
    je .sf_sec
    ; unknown verb: emit "%<c>" literally (DL: .sf_emit spares RDX)
    mov dl, al
    mov al, '%'
    call .sf_emit
    mov al, dl
.sf_lit:
    call .sf_emit
    jmp .sf_loop
.sf_Y:
    mov eax, [r12 + 20]         ; tm_year
    add eax, 1900
    lea rdi, [rel sf_tmp]       ; render 4 digits, then emit via .sf_emit
    push rax                    ; thousands: val/1000
    mov ecx, 1000
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi], al
    pop rax
    push rax                    ; hundreds: (val%1000)/100
    mov ecx, 1000
    xor edx, edx
    div ecx
    mov eax, edx
    mov ecx, 100
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi + 1], al
    pop rax
    push rax                    ; tens: (val%100)/10
    mov ecx, 100
    xor edx, edx
    div ecx
    mov eax, edx
    mov ecx, 10
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi + 2], al
    pop rax                     ; ones: val%10
    mov ecx, 10
    xor edx, edx
    div ecx
    add edx, '0'
    mov [rdi + 3], dl
    mov al, [rdi]               ; emit the 4 bytes (bounds-checked each)
    call .sf_emit
    mov al, [rdi + 1]
    call .sf_emit
    mov al, [rdi + 2]
    call .sf_emit
    mov al, [rdi + 3]
    call .sf_emit
    jmp .sf_loop
.sf_mon:
    mov eax, [r12 + 16]         ; tm_mon 0-based
    inc eax
    jmp .sf_put2
.sf_mday:
    mov eax, [r12 + 12]
    jmp .sf_put2
.sf_hour:
    mov eax, [r12 + 8]
    jmp .sf_put2
.sf_min:
    mov eax, [r12 + 4]
    jmp .sf_put2
.sf_sec:
    mov eax, [r12 + 0]
.sf_put2:
    ; bounds: need 2 bytes + NUL room
    lea rcx, [r13 + 3]
    cmp rcx, rsi
    jae .sf_over
    PUT2
    add r13, 2
    jmp .sf_loop
.sf_end:
    cmp r13, rsi                ; need NUL room
    jae .sf_over
    mov byte [r10], 0
    mov rax, r13
    jmp .sf_ret
.sf_over:
    xor eax, eax
    jmp .sf_ret
.sf_zero:
    xor eax, eax
    ret
.sf_emit:                       ; AL=char; needs 1 byte + NUL room
    lea rcx, [r13 + 2]
    cmp rcx, rsi
    jae .sf_over_pop            ; (emits return 0 via the shared exit;
                                ;  RSP: .sf_emit was CALLed — pop the
                                ;  return address first)
    mov [r10], al
    inc r10
    inc r13
    ret
.sf_over_pop:
    add rsp, 8                  ; discard .sf_emit return address
    xor eax, eax
.sf_ret:
    pop r13
    pop r12
    pop rbx
    ret
; (end of strftime; end of shim64 N4A.2a)

; ------------------------------------------------------------
; N4A.2d cross-link gap closures (see docs/25-n4a1-trim.md §3 + link log).
; Small leaves the kept NASM sources reference that have no handler or
; table yet: memchr/strpbrk (nasmlib fallbacks use them), atoi/abs
; (directiv/outbin), ctype functions (nctype + 30 call sites; glibc
; macros suppressed via __NO_CTYPE in dos64-config.h so these real
; functions serve), fileno/_fileno (honest -1: file.c's os_fstat path is
; compiled out without stat support, but the caller still evaluates
; fileno(f)), __isoc23_* aliases (glibc ≥2.38 C23 versioned symbols for
; strtol/strtoul/sscanf under gcc 16 defaults).
; ------------------------------------------------------------

; memchr(RDI=s, RSI=c-low-byte, RDX=n) -> RAX=match / NULL.
memchr:
    test rdx, rdx
    jz .mc_null
.mc_loop:
    mov al, [rdi]
    cmp al, sil
    je .mc_found
    inc rdi
    dec rdx
    jnz .mc_loop
.mc_null:
    xor eax, eax
    ret
.mc_found:
    mov rax, rdi
    ret

; strpbrk(RDI=s, RSI=accept) -> RAX=first match / NULL.
strpbrk:
    push rbx
    mov rbx, rsi                ; accept set
.sp_loop:
    mov al, [rdi]
    test al, al
    jz .sp_null
    mov rdx, rbx
.sp_scan:
    mov cl, [rdx]
    test cl, cl
    jz .sp_adv
    cmp al, cl
    je .sp_found
    inc rdx
    jmp .sp_scan
.sp_adv:
    inc rdi
    jmp .sp_loop
.sp_found:
    mov rax, rdi
    pop rbx
    ret
.sp_null:
    xor eax, eax
    pop rbx
    ret

; atoi(RDI=s) -> RAX=(int)strtol(s, NULL, 10). Tail call via stack args.
atoi:
    push rbx                    ; align (entry 8 -> 0) for the call below
    xor esi, esi
    mov edx, 10
    call strtol
    movsxd rax, eax             ; (strtol already computed it; narrow+extend)
    pop rbx
    ret

; ---- ctype (ASCII only). Predicates take C int (RDI); values outside
; the unsigned-char domain (incl. EOF=-1) fail like glibc. tolower/toupper
; pass through out-of-range values unchanged (C99 §7.4).
isspace:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    cmp al, ' '
    je ct_yes
    cmp al, 9
    jb ct_no
    cmp al, 13
    jbe ct_yes
    jmp ct_no

isdigit:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    cmp al, '0'
    jb ct_no
    cmp al, '9'
    ja ct_no
    mov eax, 1
    ret

isalpha:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    or al, 32                   ; fold: a-z check covers A-Z
    cmp al, 'a'
    jb ct_no
    cmp al, 'z'
    ja ct_no
    mov eax, 1
    ret

isalnum:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    cmp al, '0'
    jb ct_noA
    cmp al, '9'
    jbe ct_yes
    or al, 32
    cmp al, 'a'
    jb ct_no
    cmp al, 'z'
    ja ct_no
    mov eax, 1
    ret

isxdigit:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    cmp al, '0'
    jb ct_no
    cmp al, '9'
    jbe ct_yes
    or al, 32
    cmp al, 'a'
    jb ct_no
    cmp al, 'f'
    ja ct_no
    mov eax, 1
    ret

iscntrl:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    cmp al, 32
    jb ct_yes
    cmp al, 127
    je ct_yes
    xor eax, eax
    ret

ispunct:
    mov eax, edi
    cmp eax, 255
    ja ct_no
    cmp al, 33
    jb ct_no
    cmp al, 47
    jbe ct_yes
    cmp al, 58
    jb ct_no
    cmp al, 64
    jbe ct_yes
    cmp al, 91
    jb ct_no
    cmp al, 96
    jbe ct_yes
    cmp al, 123
    jb ct_no
    cmp al, 126
    ja ct_no
    mov eax, 1
    ret
ct_no:
    xor eax, eax
    ret
ct_yes:
    mov eax, 1
    ret
ct_noA:                         ; (isalnum below-'0' entry: alpha check follows)

tolower:
    mov eax, edi
    cmp eax, 255
    ja .tl_ret                   ; out of domain: unchanged
    cmp al, 'A'
    jb .tl_ret
    cmp al, 'Z'
    ja .tl_ret
    add eax, 32
.tl_ret:
    ret

toupper:
    mov eax, edi
    cmp eax, 255
    ja .tu_ret
    cmp al, 'a'
    jb .tu_ret
    cmp al, 'z'
    ja .tu_ret
    sub eax, 32
.tu_ret:
    ret

; fileno(RDI=fp) / _fileno: honest -1 (no OS fds; file.c's stat path is
; compiled out, but callers still evaluate fileno(f)).
fileno:
    mov eax, -1
    ret
_fileno:
    mov eax, -1
    ret

; __isoc23_* aliases (glibc >=2.38 C23 versioned entry points, gcc >=16
; default -std=gnu23) and __isoc99_* aliases (glibc's older/traditional
; ISO C99 versioned entry points for the scanf family + strtol/strtoul,
; the default redirect target for gcc <16 / -std=gnu17 and earlier —
; both are compiled here since the host toolchain doing the cross-build
; may be either vintage; only the pair the actual host glibc headers
; pick gets referenced, the other sits unused).
__isoc23_strtol:
    jmp strtol
__isoc23_strtoul:
    jmp strtoul
__isoc23_sscanf:
    jmp sscanf
__isoc99_strtol:
    jmp strtol
__isoc99_strtoul:
    jmp strtoul
__isoc99_sscanf:
    jmp sscanf
