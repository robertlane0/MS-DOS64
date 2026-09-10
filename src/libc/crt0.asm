; MS-DOS64 crt0 — C runtime start for DOS64 user programs (N3.4).
; Freestanding System V AMD64, NASM -f elf64. A child image links ONLY
; crt0 + libc64 (+ stdio64) + user objects and talks to the kernel
; EXCLUSIVELY through INT 21h traps (never direct-call kernel code, never
; link kernel objects). crt0.o must NEVER link into the kernel image
; (duplicate _start; see Makefile LIBC_KERN_SRCS comment) — it gets its
; own userland-only build rule.
; Rules (same as libc64/stdio64): 16 B RSP alignment before every CALL,
; callee-saved RBX/RBP/R12-R15 preserved, DF=0 around rep ops, NEVER use
; the red zone (live IRQs share the current stack).
;
; Entry (N2a contract): RDI = child PSP (PSP64), RSP = loader-set stack
; (alignment unknown). _start aligns RSP down immediately (nothing live
; below: _start never returns), builds argc/argv/envp, calls main, and
; exits with main's low 8 bits via AH=4Ch (which never returns; a
; paranoia loop follows the trap).
;
; Arguments come from the PSP command tail (PSP+0xA0 len 0..127, raw
; bytes at +0xA1 — length-bounded, NO terminator guaranteed): separators
; are space/tab/CR, skipped leading and collapsed. The tail is COPIED to a
; private 128 B buffer with a guaranteed NUL at [len] (the final word may
; run exactly to len with no room for in-place termination inside the
; 127 B tail — copying also leaves the PSP pristine). argv[0] is "" — the
; kernel passes no program path (documented cut; NASM only needs it for
; diagnostics). Limits: MAX_ARGS 16, extra tail args ignored.
; Environment comes from PSP+0x140 (linear pointer to NUL-joined
; "NAME=VAL" + double NUL, DOS2+ analog; NULL pointer = empty env):
; envp points INTO the block (no copy). Scan capped at 65536 B against
; corrupt blocks; MAX_ENV 32 entries.
; crt_parse_args / crt_parse_env are pure (no traps) and global so the
; host harness (and future in-guest tests) can call them directly.
; They use volatile scratch freely (RAX/RCX/RDX/R8-R11); callers keep
; live values in callee-saved regs (_start keeps the PSP in RBX).

bits 64
default rel

global _start
global crt_parse_args
global crt_parse_env

extern main

%define PSP_CMD_LEN  0xA0
%define PSP_CMD_TAIL 0xA1
%define PSP_ENV_PTR  0x140
%define TAIL_MAX     127
%define MAX_ARGS     16
%define MAX_ENV      32
%define ENV_SCAN_MAX 65536

section .bss
crt_argv: resq MAX_ARGS + 1       ; argv[0..argc-1] + NULL
crt_envp: resq MAX_ENV + 1        ; envp[0..envc-1] + NULL
crt_args_buf: resb TAIL_MAX + 1   ; private tail copy + guaranteed NUL

section .rodata
crt_empty: db 0                   ; argv[0] (no program path from kernel)

section .text

; crt_parse_args(RDI=psp, RSI=argv_out, RDX=maxargs) -> RAX=argc.
; argv[0]="" always (slot 0); tail words fill slots 1... Returns argc with
; argv_out[argc]=NULL (caller provides maxargs+1 slots; maxargs counts
; argv[0], so at most maxargs-1 real words — _start's 16 gives argv[0] +
; 15 args). NULL psp -> argc=1 (argv[0] only); NULL argv_out -> argc=0
; (nothing to fill).
; Clobbers RAX, RCX, R8-R11 (RSI/RDI/RDX preserved).
crt_parse_args:
    test rsi, rsi
    jz .pa_noarray
    lea rax, [rel crt_empty]
    mov [rsi], rax                ; argv[0] = ""
    mov ecx, 1                    ; argc = 1
    test rdi, rdi
    jz .pa_done                   ; NULL psp: argv[0] only
    test rdx, rdx
    jz .pa_done                   ; maxargs 0: argv[0] only
    movzx r8d, byte [rdi + PSP_CMD_LEN]
    cmp r8, TAIL_MAX
    jbe .pa_lenok
    mov r8d, TAIL_MAX             ; clamp corrupt lengths to the buffer
.pa_lenok:
    lea r9, [rdi + PSP_CMD_TAIL]  ; src = tail
    lea r10, [rel crt_args_buf]   ; dst = private copy
    mov r11, r8                   ; count
    test r11, r11
    jz .pa_copied
.pa_copy:
    mov al, [r9]
    mov [r10], al
    inc r9
    inc r10
    dec r11
    jnz .pa_copy
.pa_copied:
    mov byte [r10], 0             ; guaranteed NUL at [buf+len] (128 B buf:
                                  ; len <= 127 so this is always in bounds)
    lea r9, [rel crt_args_buf]    ; p = buf
    lea r10, [r9 + r8]            ; end = buf + len (NUL sits at [end])
.pa_skip:
    cmp r9, r10
    jae .pa_done
    mov al, [r9]
    cmp al, ' '
    je .pa_adv
    cmp al, 9                     ; TAB
    je .pa_adv
    cmp al, 13                    ; CR (shell tails may carry one)
    jne .pa_word
.pa_adv:
    inc r9
    jmp .pa_skip
.pa_word:
    cmp rcx, rdx                  ; argc < maxargs?
    jae .pa_done                  ; table full: ignore the rest
    mov [rsi + rcx*8], r9         ; argv[argc] = word start
    inc rcx
.pa_scan:
    cmp r9, r10
    jae .pa_done
    mov al, [r9]
    cmp al, ' '
    je .pa_end
    cmp al, 9
    je .pa_end
    cmp al, 13
    je .pa_end
    inc r9
    jmp .pa_scan
.pa_end:
    mov byte [r9], 0              ; terminate in place (p < end: in bounds)
    inc r9
    jmp .pa_skip
.pa_done:
    cmp rcx, rdx                  ; argc <= maxargs? (== only when the table
    ja .pa_ret                   ; filled exactly; > only for maxargs=0, where
    mov qword [rsi + rcx*8], 0    ; argv[argc] = NULL (slot provided per contract)
.pa_ret:
    mov rax, rcx
    ret
.pa_noarray:
    xor eax, eax
    ret

; crt_parse_env(RDI=psp, RSI=envp_out, RDX=maxenv) -> RAX=envc.
; envp[i] point into the env block (no copy); envp_out[envc]=NULL
; (caller provides maxenv+1 slots). NULL psp, NULL env pointer, or an
; empty block (first byte NUL) -> envc=0. Scan capped at ENV_SCAN_MAX.
; Clobbers RAX, RCX, R8-R10 (RSI/RDI/RDX preserved).
crt_parse_env:
    test rsi, rsi
    jz .pe_noarray
    xor ecx, ecx                  ; envc = 0
    test rdi, rdi
    jz .pe_done                   ; NULL psp: empty env
    mov r8, [rdi + PSP_ENV_PTR]   ; env block (may be NULL)
    test r8, r8
    jz .pe_done
    mov r9, r8
    add r9, ENV_SCAN_MAX          ; hard stop against corrupt blocks
.pe_loop:
    cmp r8, r9
    jae .pe_done                  ; hit the cap: stop honestly
    mov al, [r8]
    test al, al
    jz .pe_done                   ; NUL: empty block or double-NUL end
    cmp rcx, rdx                  ; envc < maxenv?
    jae .pe_done                  ; table full: ignore the rest
    mov [rsi + rcx*8], r8         ; envp[envc] = entry
    inc rcx
.pe_adv:
    cmp r8, r9
    jae .pe_cap                   ; cap inside the entry: drop the partial
    mov al, [r8]                  ; (unterminated) so envp holds only complete
    inc r8                        ; NUL-terminated strings
    test al, al
    jnz .pe_adv                   ; advance past the entry's NUL
    jmp .pe_loop
.pe_cap:
    dec rcx                       ; un-store the partial entry pointer
    jmp .pe_done
.pe_done:
    mov qword [rsi + rcx*8], 0    ; envp[envc] = NULL
    mov rax, rcx
    ret
.pe_noarray:
    xor eax, eax
    ret

; _start — RDI=PSP on entry (N2a). Align stack, parse, call main, exit.
_start:
    and rsp, -16                  ; align (nothing live below; never returns)
    push rbx
    push r12                      ; 2 pushes: RSP%16==0 again, call-safe
    mov rbx, rdi                  ; PSP (callee-saved across the parsers)
    lea rsi, [rel crt_argv]
    mov edx, MAX_ARGS
    call crt_parse_args           ; RAX = argc
    mov r12d, eax                 ; argc (int range: tail-bounded)
    mov rdi, rbx
    lea rsi, [rel crt_envp]
    mov edx, MAX_ENV
    call crt_parse_env            ; envp filled (count in RAX, unused here)
    mov edi, r12d                 ; argc
    lea rsi, [rel crt_argv]       ; argv
    lea rdx, [rel crt_envp]       ; envp
    call main
    ; exit with main's low 8 bits: AL already holds them; set AH last and
    ; zero every other volatile (stale regs are live trap inputs).
    xor ebx, ebx
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov ah, 0x4C
    int 0x21
.hang:
    jmp .hang                     ; 4Ch never returns; paranoia
