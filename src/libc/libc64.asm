; MS-DOS64 libc64 — C library core for DOS64 user programs (N3.1 + N3.2).
; Freestanding System V AMD64, NASM -f elf64. A child image links ONLY
; crt0 + libc64 (+ stdio64) + user objects and talks to the kernel
; EXCLUSIVELY through INT 21h traps: never direct-call kernel code (separate
; link, separate -D flags, no shared addresses) and never link kernel objects.
; Self-contained string code (NOT src/lib/*): the kernel's memcpy64 et al.
; serve the kernel build; these C-named versions are trivially auditable and
; keep child images free of kernel-build coupling and demo bss bloat.
; Rules: 16 B RSP alignment before every CALL, callee-saved RBX/RBP/R12-R15
; preserved, DF=0 around rep ops, NEVER use the red zone (live IRQs share
; the current stack, so [RSP-128,RSP) is unsound here — always sub rsp /
; push first; user C code must use -mno-red-zone for the same reason).
; Trap discipline (see idt64 int21_entry: all GPRs restored from the trap
; frame, RAX from the handler-written slot, CF propagated): set EVERY arg
; reg explicitly per call (stale regs are live inputs to some handlers!);
; afterwards ONLY RAX and CF are meaningful — test CF FIRST with jc/jnc.
; In particular: AH=48h reads RBX=paragraphs ONLY when RDI==0, so zero RDI
; on the trap path; AH=02h has no meaningful CF (VGA authoritative), ignore
; it; AH=49h/4Ch-style handlers that skip the frame write leave RAX as input.
; Printf-family design: bare verbs only ({d,i,u,x,X,p,s,c,%}, no width /
; precision / flags / length modifiers — N4+ if a client needs them);
; GP-class varargs only (matches the verb set; no float verbs exist).
; C-sized verbs: %d/%i/%u/%x/%X consume C int (low 32 bits, d/i sign-extended
; via movsxd; upper vararg bits are undefined per ABI and ignored) — glibc
; parity, and the widest %d edge is INT32_MIN (11 chars). %p takes the full
; 64-bit pointer; %c takes the low byte (C promotion); %s takes the pointer.
; A single file-local va_next serves printf/sprintf/snprintf: per-function
; setup spills the reg args into 5 slots (copying the first stack args in
; where the signature has fewer than 5 reg varargs) so the walk is uniform:
; index<5 -> spill[index], else overflow_base+(index-5)*8. Reading a stack
; slot the caller never passed yields stack garbage (same as stock ABI UB),
; never a fault (child stack is mapped). Unknown verbs emit literally as
; "%<c>"; a lone trailing % emits '%'.

bits 64
default rel

global memcpy
global memmove
global memset
global memcmp
global strlen
global strcpy
global strncpy
global strcmp
global strncmp
global strcat
global strchr
global malloc
global calloc
global realloc
global free
global putchar
global puts
global printf
global sprintf
global snprintf
global exit
global null_str                   ; N4A.2b: shared with stdio64 vfprintf
global hexdig_lo
global hexdig_hi
global pf_pctch
global octdig

section .rodata
null_str: db "(null)",0
hexdig_lo: db "0123456789abcdef"
hexdig_hi: db "0123456789ABCDEF"
octdig: db "01234567"
pf_pctch: db '%'

section .text

; ------------------------------------------------------------
; memcpy(RDI=dst, RSI=src, RDX=n) -> RAX=dst. Overlap is UB (use memmove).
memcpy:
    mov rax, rdi
    mov rcx, rdx
    cld
    rep movsb
    ret

; memmove(RDI=dst, RSI=src, RDX=n) -> RAX=dst. Overlap-safe both ways
; (rep movsb preserves RAX, so the pre-saved dst survives either direction).
memmove:
    mov rax, rdi
    test rdx, rdx
    jz .mm_done
    cmp rdi, rsi
    jb .mm_fwd
    je .mm_done
    lea rsi, [rsi + rdx - 1]
    lea rdi, [rdi + rdx - 1]
    mov rcx, rdx
    std
    rep movsb
    cld
    ret
.mm_fwd:
    mov rcx, rdx
    cld
    rep movsb
    ret
.mm_done:
    ret

; memset(RDI=s, RSI=c, RDX=n) -> RAX=s. Only the low byte of RSI is used.
memset:
    push rdi
    mov rcx, rdx
    mov al, sil
    cld
    rep stosb
    pop rax
    ret

; memcmp(RDI=a, RSI=b, RDX=n) -> RAX: 0 equal, else sign of the first
; differing UNSIGNED byte pair (-1/0/1; sign-only, like glibc's contract).
memcmp:
    test rdx, rdx
    jz .mc_eq
.mc_loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .mc_diff
    inc rdi
    inc rsi
    dec rdx
    jnz .mc_loop
.mc_eq:
    xor eax, eax
    ret
.mc_diff:
    mov eax, 1
    ja .mc_done                 ; flags still hold (cmp al,cl); mov keeps them
    mov rax, -1                 ; full 64-bit -1: C callers test < 0, and
.mc_done:                       ; mov eax,-1 would zero-extend to +4G (wrong)
    ret

; strlen(RDI=s) -> RAX=len, not counting NUL. NULL input faults (as in glibc).
strlen:
    xor eax, eax
    mov rcx, -1
    cld
    repne scasb
    not rcx
    dec rcx
    mov rax, rcx
    ret

; strcpy(RDI=dst, RSI=src) -> RAX=dst, NUL included.
strcpy:
    mov rax, rdi
.sc_loop:
    mov cl, [rsi]
    mov [rdi], cl
    inc rsi
    inc rdi
    test cl, cl
    jnz .sc_loop
    ret

; strncpy(RDI=dst, RSI=src, RDX=n) -> RAX=dst. Copies up to n, pads the
; remainder with NULs; if no NUL appears in the first n, dst is unterminated.
strncpy:
    mov rax, rdi
    test rdx, rdx
    jz .sn_done
.sn_copy:
    mov cl, [rsi]
    mov [rdi], cl
    inc rsi
    inc rdi
    dec rdx
    jz .sn_done
    test cl, cl
    jnz .sn_copy
.sn_pad:
    test rdx, rdx
    jz .sn_done
    mov byte [rdi], 0
    inc rdi
    dec rdx
    jmp .sn_pad
.sn_done:
    ret

; strcmp(RDI=a, RSI=b) -> -1/0/1 on UNSIGNED bytes.
strcmp:
.scmp_loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .scmp_diff
    test al, al
    jz .scmp_eq
    inc rdi
    inc rsi
    jmp .scmp_loop
.scmp_eq:
    xor eax, eax
    ret
.scmp_diff:
    mov eax, 1
    ja .scmp_done                ; cmp flags survive jne+mov
    mov rax, -1                 ; full 64-bit -1 (see memcmp note)
.scmp_done:
    ret

; strncmp(RDI=a, RSI=b, RDX=n) -> -1/0/1. n==0 compares nothing -> 0.
strncmp:
    test rdx, rdx
    jz .sn_eq
.sn_loop:
    mov al, [rdi]
    mov cl, [rsi]
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
    ja .sn_done2
    mov rax, -1                 ; full 64-bit -1 (see memcmp note)
.sn_done2:
    ret

; strcat(RDI=dst, RSI=src) -> RAX=dst.
strcat:
    mov rax, rdi
.scat_find:
    cmp byte [rdi], 0
    je .scat_copy
    inc rdi
    jmp .scat_find
.scat_copy:
    mov cl, [rsi]
    mov [rdi], cl
    inc rsi
    inc rdi
    test cl, cl
    jnz .scat_copy
    ret

; strchr(RDI=s, RSI=c) -> RAX=first match or NULL (c==0 matches the NUL).
strchr:
.sch_loop:
    mov al, [rdi]
    cmp al, sil
    je .sch_found
    test al, al
    jz .sch_miss
    inc rdi
    jmp .sch_loop
.sch_found:
    mov rax, rdi
    ret
.sch_miss:
    xor eax, eax
    ret

; ------------------------------------------------------------
; Heap over AH=48h/49h (N3.2). Each malloc is one kernel alloc. Kernel
; blocks are NOT address-aligned (mem_alloc64 aligns sizes; 40B headers
; alternate payloads between %16==0/8), so libc aligns manually: the 24B
; header [MAGIC,size,base] sits immediately below the 16-aligned payload
; (base = true kernel address for 49h). No coalescing across libc blocks
; (documented waste); realloc = alloc + copy + free (AH=4Ah deliberately
; unused — fewer moving parts).
%define HEAP_MAGIC  0xABAD1DEAABAD1DEA
%define HEAP_HDRSZ  24
%define HEAP_PAD    15          ; align slop: payload=(base+24+15)&~15

; malloc(RDI=size) -> RAX=16-aligned ptr/NULL. Size 0 yields minimal block.
malloc:
    push rdi                    ; requested size (entry 8 -> 0, balanced below)
    test rdi, rdi
    jnz .m_sz
    mov qword [rsp], 1
.m_sz:
    mov rax, [rsp]
    add rax, HEAP_HDRSZ+HEAP_PAD  ; size+39; wraps -> CF -> NULL
    jc .m_null
    add rax, 15
    jc .m_null
    shr rax, 4                  ; paragraphs (min total 40 -> 3, never 0)
    push rbx                    ; RBX is callee-saved: preserve across use
    mov rbx, rax
    xor edi, edi                ; TRAP HAZARD: 48h takes RDI bytes if nonzero
    mov eax, 0x4800
    int 0x21
    pop rbx                     ; (int preserves it too; belt and suspenders)
    jc .m_null                  ; CF first: RAX meaningless on failure
    lea rcx, [rax + HEAP_HDRSZ + HEAP_PAD]
    and rcx, -16                ; payload: first 16-aligned addr past header
    mov rdx, HEAP_MAGIC         ; movabs: 64-bit immediates need a register
    mov [rcx - HEAP_HDRSZ], rdx
    mov rdx, [rsp]              ; requested size
    mov [rcx - HEAP_HDRSZ + 8], rdx
    mov [rcx - HEAP_HDRSZ + 16], rax   ; true base for 49h
    ; Zero the payload. Many ported C codebases (NASM's included) have a
    ; latent "malloc returns zeroed memory" assumption — technically UB,
    ; but it silently "works" on Linux because fresh mmap pages are
    ; kernel-zeroed. DOS64's AH=48h allocator hands out raw, recycled
    ; MCB bytes (real MS-DOS semantics: uninitialized, like glibc's
    ; malloc really promises), so a freshly malloc'd block can contain
    ; stale bytes from whatever occupied that memory before (e.g. a
    ; just-freed EXEC staging buffer full of another program's machine
    ; code) and a latent "assumes zero" field read turns into a wild
    ; pointer instead of NULL/0 (PLAN.md N4A.4 finding: this is exactly
    ; what broke NASM64.COM's first fputs() — a garbage RDI faulting
    ; #GP on the first character read).
    push rcx                    ; payload ptr (becomes the return value)
    push rdi
    push rsi
    mov rdi, rcx                ; dest = payload
    mov rcx, rdx                ; count = requested size (rdx still live)
    xor eax, eax
    cld
    rep stosb
    pop rsi
    pop rdi
    pop rax                     ; payload ptr -> return value
    add rsp, 8
    ret
.m_null:
    add rsp, 8
    xor eax, eax
    ret

; free(RDI=p) — NULL, misaligned, or bad-magic pointers are silent no-ops.
free:
    test rdi, rdi
    jz .f_done
    test rdi, 15                ; payloads are always 16-aligned; anything
    jnz .f_done                 ; else cannot be ours (cheap wild-pointer cut)
    mov rax, HEAP_MAGIC         ; movabs compare (no imm64 cmp encoding)
    cmp [rdi - HEAP_HDRSZ], rax
    jne .f_done
    mov rdi, [rdi - HEAP_HDRSZ + 16]   ; true base (never the payload)
    test rdi, rdi               ; (paranoia: base 0 would hit the IVT path)
    jz .f_done
    mov eax, 0x4900
    int 0x21                    ; result ignored: nothing sane to do on failure
.f_done:
    ret

; calloc(RDI=nmemb, RSI=size) -> zeroed array or NULL (overflow-safe).
calloc:
    mov rax, rdi
    mul rsi                     ; RDX:RAX = nmemb*size, unsigned
    test rdx, rdx
    jnz .c_null                 ; overflow
    push rax                    ; total (entry 8 -> 0: aligned for calls)
    mov rdi, rax
    call malloc                 ; malloc(0) is live; memset(0) is a no-op
    test rax, rax
    jz .c_fail
    mov rdi, rax
    mov rdx, [rsp]
    xor esi, esi
    call memset                 ; RAX=dst passes straight through
    add rsp, 8
    ret
.c_fail:
    add rsp, 8
.c_null:
    xor eax, eax
    ret

; realloc(RDI=old, RSI=newsize) -> resized or NULL (old intact on failure).
; NULL old behaves like malloc; newsize 0 frees and returns NULL. Wild old
; pointers (bad magic) degrade to malloc-fresh rather than faulting.
realloc:
    test rdi, rdi
    jnz .r_no_null
    mov rdi, rsi
    jmp malloc                  ; tail call: stack already balanced
.r_no_null:
    test rsi, rsi
    jnz .r_no_zero
    call free                   ; RDI=old still live
    xor eax, eax
    ret
.r_no_zero:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8                  ; 4 pushes + 8 = 40: entry 8 -> 0, aligned
    mov r12, rdi                ; old
    mov r13, rsi                ; newsize
    cmp rdi, HEAP_HDRSZ
    jb .r_fresh
    mov rax, HEAP_MAGIC
    cmp [rdi - HEAP_HDRSZ], rax
    jne .r_fresh
    mov rax, [rdi - HEAP_HDRSZ + 8]   ; old requested size
    cmp rax, r13
    cmova rax, r13              ; copy = min(old, new)
    mov rbx, rax                ; stash count (memcpy preserves RBX: untouched)
    mov rdi, r13
    call malloc
    test rax, rax
    jz .r_fail
    mov r14, rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, rbx
    call memcpy
    mov rdi, r12
    call free
    mov rax, r14
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.r_fail:                        ; malloc failed: old block untouched
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
.r_fresh:                       ; wild old pointer: malloc fresh, touch nothing
    mov rdi, r13
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp malloc

; ------------------------------------------------------------
; Console output over AH=02h (N3.1). CF from INT 21h/02h is meaningless
; (VGA authoritative; handler leaves whatever flags vga_putc left), so
; output functions never consult it.

; putchar(RDI=c) -> RAX=(unsigned char)c. Cannot fail.
putchar:
    mov dl, dil
    mov eax, 0x0200
    int 0x21
    movzx eax, dil              ; RDI survives the trap (frame restore)
    ret

; puts(RDI=s) -> RAX=0 ok, -1 (EOF) on NULL input. Appends '\n' (glibc).
puts:
    test rdi, rdi
    jz .puts_eof
    push rbx
    push r12
    sub rsp, 8                  ; 2 pushes + 8 = 24: entry 8 -> 0, aligned
    mov r12, rdi
.puts_loop:
    mov al, [r12]
    test al, al
    jz .puts_nl
    movzx edi, al
    call putchar                ; preserves RBX/R12 (callee-saved discipline)
    inc r12
    jmp .puts_loop
.puts_nl:
    mov edi, 10
    call putchar
    xor eax, eax
    add rsp, 8
    pop r12
    pop rbx
    ret
.puts_eof:
    mov rax, -1                 ; full 64-bit EOF (C callers test < 0)
    ret

; Shared vararg walker for the printf family (see header contract).
; Setup per function spills reg args into 5 slots (copying the first stack
; args in where the signature has fewer than 5 reg varargs) and sets:
;   R14 = arg index (caller zeroes), R15 = spill base, R10 = overflow base
;   (uniform formula: index<5 -> spill[index], else base+(index-5)*8).
; In: R14=index (caller zeroes once per format call). Out: RAX=value
; (index incremented). Clobbers only RAX (+R14 as its counter).
va_next:
    cmp r14, 5
    jae .va_stack
    mov rax, [r15 + r14*8]
    inc r14
    ret
.va_stack:
    mov rax, r14
    sub rax, 5
    shl rax, 3
    add rax, r10
    mov rax, [rax]
    inc r14
    ret

; printf(RDI=fmt, ...) -> RAX=chars emitted.
; Verbs: flags '-'/'0', width (digits/'*'), precision ('.'digits/'.*'),
; lengths h(ignored)/l/ll/z(64-bit value), conversions d/i/u/o/x/X/p/s/c/%.
; %d/%i/%u/%o/%x/%X are C int (low 32) unless l/ll/z selects 64 bits;
; %p is always 64-bit. prec==0 with numeric 0 renders empty (C99).
; Unknown verbs emit literally as "%<c>"; a lone trailing % emits '%'.
; Frame: 5 pushes (40B: entry 8 -> 0) + sub 96 ([rsp,rsp+40) reg spill of
; RSI..R9, [rsp+40] width, [rsp+48] prec, [rsp+56] eptr, [rsp+64] elen,
; [rsp+72,rsp+96) 24B numbuf). Live: RBX=fmt, R13=count, R14=idx,
; R15=spill base, R10=overflow base (entry+8 == rsp+144). R11D=flags
; (bit0 LEFT, bit1 ZERO, bit2 IS64, bit3 HAS_PREC).
printf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov [rsp+0], rsi
    mov [rsp+8], rdx
    mov [rsp+16], rcx
    mov [rsp+24], r8
    mov [rsp+32], r9
    lea r15, [rsp]
    lea r10, [rsp+144]
    xor r13d, r13d              ; out count
    xor r14d, r14d              ; arg index
    mov rbx, rdi                ; fmt cursor
.pf_loop:
    mov al, [rbx]
    test al, al
    jz .pf_done
    cmp al, '%'
    je .pf_verb
    movzx edi, al
    call putchar
    inc r13
    inc rbx
    jmp .pf_loop
.pf_verb:
    inc rbx                     ; past '%'
    call .pf_adv                ; AL = first spec char
    jz .pf_pct_end              ; lone trailing %: emit it, stop
    xor r11d, r11d              ; flags
    mov qword [rsp+40], -1      ; width: none
    mov qword [rsp+48], -1      ; prec: none
.pf_flag:
    cmp al, '-'
    jne .pf_fl1
    or r11d, 1
    call .pf_adv
    jz .pf_done
    jmp .pf_flag
.pf_fl1:
    cmp al, '0'
    jne .pf_width
    or r11d, 2
    call .pf_adv
    jz .pf_done
    jmp .pf_flag
.pf_width:
    cmp al, '*'
    jne .pf_wdigits
    call va_next                ; width from arg (negative: LEFT + positive)
    test eax, eax
    jns .pf_wstore
    or r11d, 1
    neg eax
.pf_wstore:
    movsxd rax, eax
    mov [rsp+40], rax
    call .pf_adv
    jz .pf_done
    jmp .pf_prec
.pf_wdigits:
    cmp al, '0'
    jb .pf_prec
    cmp al, '9'
    ja .pf_prec
    xor ecx, ecx
.pf_wloop:
    imul ecx, ecx, 10
    movzx eax, al
    sub eax, '0'
    add ecx, eax
    call .pf_adv
    jz .pf_wdone0
    cmp al, '0'
    jb .pf_wdone
    cmp al, '9'
    ja .pf_wdone
    jmp .pf_wloop
.pf_wdone0:
    movsxd rcx, ecx
    mov [rsp+40], rcx
    jmp .pf_done
.pf_wdone:
    movsxd rcx, ecx
    mov [rsp+40], rcx
.pf_prec:
    cmp al, '.'
    jne .pf_len
    call .pf_adv                ; '.' consumed; bare '.' means prec 0
    jz .pf_pdone0
    mov qword [rsp+48], 0
    or r11d, 8                  ; HAS_PREC
    cmp al, '*'
    jne .pf_pdigits
    call va_next
    test eax, eax
    js .pf_pnone                ; negative prec: none (C99)
    movsxd rax, eax
    mov [rsp+48], rax
    or r11d, 8                  ; HAS_PREC
    call .pf_adv
    jz .pf_done
    jmp .pf_len
.pf_pnone:
    mov qword [rsp+48], -1
    call .pf_adv
    jz .pf_done
    jmp .pf_len
.pf_pdone0:
    mov qword [rsp+48], 0
    jmp .pf_done
.pf_pdigits:
    cmp al, '0'
    jb .pf_len
    cmp al, '9'
    ja .pf_len
    xor ecx, ecx
.pf_ploop:
    imul ecx, ecx, 10
    movzx eax, al
    sub eax, '0'
    add ecx, eax
    call .pf_adv
    jz .pf_pdone0b
    cmp al, '0'
    jb .pf_pdone
    cmp al, '9'
    ja .pf_pdone
    jmp .pf_ploop
.pf_pdone0b:
    movsxd rcx, ecx
    mov [rsp+48], rcx
    jmp .pf_done
.pf_pdone:
    movsxd rcx, ecx
    mov [rsp+48], rcx
    or r11d, 8                  ; HAS_PREC
.pf_len:
    cmp al, 'h'
    jne .pf_l1
    call .pf_adv                ; h/hh accepted, ignored (int slots)
    jz .pf_done
    cmp al, 'h'
    jne .pf_conv
    call .pf_adv
    jz .pf_done
    jmp .pf_conv
.pf_l1:
    cmp al, 'l'
    jne .pf_l2
    or r11d, 4                  ; l/ll: 64-bit value
    call .pf_adv
    jz .pf_done
    cmp al, 'l'
    jne .pf_conv
    call .pf_adv
    jz .pf_done
    jmp .pf_conv
.pf_l2:
    cmp al, 'z'                 ; z: size_t (64-bit here)
    jne .pf_conv
    or r11d, 4
    call .pf_adv
    jz .pf_done
.pf_conv:
    cmp al, '%'
    je .pf_pct
    cmp al, 'c'
    je .pf_c
    cmp al, 's'
    je .pf_s
    cmp al, 'd'
    je .pf_d
    cmp al, 'i'
    je .pf_d
    cmp al, 'u'
    je .pf_u
    cmp al, 'o'
    je .pf_o
    cmp al, 'x'
    je .pf_x
    cmp al, 'X'
    je .pf_X
    cmp al, 'p'
    je .pf_p
    jmp .pf_unknown             ; anything else: emit "%<c>" literally
.pf_adv:                        ; next fmt char into AL (ZF set on NUL).
    mov al, [rbx]               ; callers follow with `jz .pf_done`
    inc rbx
    test al, al
    ret
.pf_pct:
    test r11d, 2                ; '0' flag: zero pad (C allows %05%)
    jz .pf_pctsp
    mov r8b, '0'
    jmp .pf_pctgo
.pf_pctsp:
    mov r8b, ' '
.pf_pctgo:
    lea rsi, [rel pf_pctch]
    mov rcx, 1
    jmp .pf_stremit
.pf_pct_end:
    mov edi, '%'
    call putchar
    inc r13
    jmp .pf_done
.pf_unknown:
    mov rcx, rax                ; stash verb (RCX dead here; putchar spares it)
    mov edi, '%'
    call putchar
    inc r13
    mov rax, rcx
    movzx edi, al
    call putchar
    inc r13
    jmp .pf_loop
.pf_c:
    call va_next
    movzx eax, al               ; low byte only (C int promotion)
    mov [rsp+72], al            ; 1-byte body in numbuf scratch
    lea rsi, [rsp+72]
    mov rcx, 1
    mov r8b, ' '                ; '0' ignored for %c
    jmp .pf_stremit
.pf_s:
    call va_next
    test rax, rax
    jnz .pf_s_str
    lea rax, [rel null_str]
.pf_s_str:
    mov rsi, rax
    mov rcx, [rsp+48]           ; prec: max chars (-1: unbounded)
    cmp rcx, -1
    je .pf_s_full
    xor r8d, r8d                ; bounded length count
.pf_s_cap:
    cmp r8, rcx
    jae .pf_s_got
    cmp byte [rsi + r8], 0
    je .pf_s_got
    inc r8
    jmp .pf_s_cap
.pf_s_got:
    mov rcx, r8
    jmp .pf_s_emit
.pf_s_full:
    xor ecx, ecx                ; strlen loop
.pf_s_cnt:
    cmp byte [rsi + rcx], 0
    je .pf_s_emit
    inc rcx
    jmp .pf_s_cnt
.pf_s_emit:
    mov r8b, ' '                ; strings always space-pad
    jmp .pf_stremit
.pf_d:
    call va_next
    test r11d, 4                ; 64-bit value?
    jnz .pf_d64
    movsxd rax, eax             ; C int: low 32, sign-extended
.pf_d64:
    test rax, rax
    jns .pf_dpos
    mov r8b, '-'                ; sign
    neg rax                     ; magnitude as unsigned (MIN wraps ok)
    jmp .pf_dmag
.pf_dpos:
    xor r8b, r8b
.pf_dmag:
    lea rdi, [rsp+96]
    cmp qword [rsp+48], 0       ; prec==0 && value==0 renders empty (C99)
    jne .pf_dorender
    test rax, rax
    jz .pf_dempty
.pf_dorender:
    call .pf_udiv10
    jmp .pf_numemit
.pf_dempty:
    lea rsi, [rdi]
    xor ecx, ecx
    jmp .pf_numemit
.pf_u:
    call va_next
    test r11d, 4
    jnz .pf_u64
    shl rax, 32                 ; C unsigned int: low 32
    shr rax, 32
.pf_u64:
    xor r8b, r8b
    lea rdi, [rsp+96]
    cmp qword [rsp+48], 0
    jne .pf_urender
    test rax, rax
    jz .pf_uempty
.pf_urender:
    call .pf_udiv10
    jmp .pf_numemit
.pf_uempty:
    lea rsi, [rdi]
    xor ecx, ecx
    jmp .pf_numemit
.pf_o:
    call va_next
    test r11d, 4
    jnz .pf_o64
    shl rax, 32
    shr rax, 32
.pf_o64:
    xor r8b, r8b
    lea rdi, [rsp+96]
    cmp qword [rsp+48], 0
    jne .pf_orender
    test rax, rax
    jz .pf_oempty
.pf_orender:
    call .pf_uoct
    jmp .pf_numemit
.pf_oempty:
    lea rsi, [rdi]
    xor ecx, ecx
    jmp .pf_numemit
.pf_x:
    call va_next
    test r11d, 4
    jnz .pf_x64
    shl rax, 32
    shr rax, 32
.pf_x64:
    xor r8b, r8b
    lea r12, [rel hexdig_lo]
    lea rdi, [rsp+96]
    cmp qword [rsp+48], 0
    jne .pf_xrender
    test rax, rax
    jz .pf_xempty
.pf_xrender:
    call .pf_uhex
    jmp .pf_numemit
.pf_xempty:
    lea rsi, [rdi]
    xor ecx, ecx
    jmp .pf_numemit
.pf_X:
    call va_next
    test r11d, 4
    jnz .pf_X64
    shl rax, 32
    shr rax, 32
.pf_X64:
    xor r8b, r8b
    lea r12, [rel hexdig_hi]
    lea rdi, [rsp+96]
    cmp qword [rsp+48], 0
    jne .pf_Xrender
    test rax, rax
    jz .pf_Xempty
.pf_Xrender:
    call .pf_uhex
    jmp .pf_numemit
.pf_Xempty:
    lea rsi, [rdi]
    xor ecx, ecx
    jmp .pf_numemit
.pf_p:
    call va_next                ; full 64-bit value, "0x" + hex
    lea r12, [rel hexdig_lo]
    lea rdi, [rsp+96]
    call .pf_uhex               ; RSI=hex, RCX=hexlen ("0" for 0)
    mov [rsp+56], rsi           ; stash hex across prefix emit
    mov [rsp+64], rcx
    ; pad target: width covers "0x"+hex; ZERO pads after 0x, else spaces.
    mov rax, [rsp+40]           ; width
    cmp rax, -1
    je .pf_pplain               ; no width: straight "0x"+hex
    mov rdx, [rsp+64]
    add rdx, 2                  ; body = hex + 2
    sub rax, rdx                ; pad = width - body
    jbe .pf_pplain              ; (<= 0: none)
    mov rcx, rax                ; pad count
    test r11d, 1                ; LEFT?
    jnz .pf_pleft
    test r11d, 2                ; ZERO?
    jz .pf_ppadsp
    ; zeros after 0x: emit "0x", zero pad, hex
    mov edi, '0'
    call putchar
    inc r13
    mov edi, 'x'
    call putchar
    inc r13
    mov edi, '0'
    call .pf_pad
    jmp .pf_phex
.pf_ppadsp:
    mov edi, ' '
    call .pf_pad
.pf_pplain:
    mov edi, '0'
    call putchar
    inc r13
    mov edi, 'x'
    call putchar
    inc r13
.pf_phex:
    mov rsi, [rsp+56]
    mov rcx, [rsp+64]
    call .pf_emitstr
    jmp .pf_loop
.pf_pleft:
    mov edi, '0'
    call putchar
    inc r13
    mov edi, 'x'
    call putchar
    inc r13
    mov rsi, [rsp+56]
    mov rcx, [rsp+64]
    call .pf_emitstr
    mov edi, ' '
    call .pf_pad
    jmp .pf_loop
; .pf_numemit: R8B=sign (0/'-'), RSI=digits, RCX=ndigits. Width/prec/ZERO/
; LEFT from stack/flags. Sequences [pad][sign][zeros][digits] per C rules.
.pf_numemit:
    mov [rsp+56], rsi
    mov [rsp+64], rcx
    mov rax, [rsp+48]           ; prec
    cmp rax, -1
    je .pf_nm_noprec
    sub rax, rcx                ; prec - ndigits
    jbe .pf_nm_noprec           ; <= 0: no zero fill
    mov r9d, eax                ; prec zeros (int range: widths are small)
    jmp .pf_nm_body
.pf_nm_noprec:
    xor r9d, r9d
.pf_nm_body:
    mov rax, rcx                ; body = ndigits + preczeros + sign?
    add rax, r9
    test r8b, r8b
    jz .pf_nm_nosign
    inc rax
.pf_nm_nosign:
    mov rdx, [rsp+40]           ; width
    cmp rdx, -1
    je .pf_nm_nowidth
    sub rdx, rax                ; pad = width - body
    ja .pf_nm_padok
.pf_nm_nowidth:
    xor edx, edx
.pf_nm_padok:
    mov [rsp+40], rdx             ; pad count (width slot, consumed;
                                ; R10 is volatile across putchar calls)
    test r11d, 1                ; LEFT?
    jnz .pf_nm_left
    test r11d, 2                ; ZERO (ignored when prec present)?
    jz .pf_nm_padsp
    test r11d, 8                ; HAS_PREC?
    jnz .pf_nm_padsp
    ; zero pad after sign
    test r8b, r8b
    jz .pf_nm_zpad
    movzx edi, r8b
    call putchar
    inc r13
.pf_nm_zpad:
    mov ecx, [rsp+40]
    mov edi, '0'
    call .pf_pad
    jmp .pf_nm_digits
.pf_nm_padsp:
    mov ecx, [rsp+40]
    mov edi, ' '
    call .pf_pad
    test r8b, r8b
    jz .pf_nm_zeros
    movzx edi, r8b
    call putchar
    inc r13
.pf_nm_zeros:
    mov ecx, r9d
    mov edi, '0'
    call .pf_pad
.pf_nm_digits:
    mov rsi, [rsp+56]
    mov rcx, [rsp+64]
    call .pf_emitstr
    jmp .pf_loop
.pf_nm_left:
    test r8b, r8b
    jz .pf_nm_lzeros
    movzx edi, r8b
    call putchar
    inc r13
.pf_nm_lzeros:
    mov ecx, r9d
    mov edi, '0'
    call .pf_pad
    mov rsi, [rsp+56]
    mov rcx, [rsp+64]
    call .pf_emitstr
    mov ecx, [rsp+40]
    mov edi, ' '
    call .pf_pad
    jmp .pf_loop
; .pf_stremit: R8B=padchar, RSI=ptr, RCX=len. Width pads (LEFT aware).
.pf_stremit:
    mov [rsp+56], rsi
    mov [rsp+64], rcx
    mov rax, [rsp+40]           ; width
    cmp rax, -1
    je .pf_strbody
    sub rax, rcx                ; pad = width - len
    jbe .pf_strbody
    mov [rsp+40], rax             ; pad (width slot, consumed)
    test r11d, 1
    jnz .pf_strleft
    mov ecx, [rsp+40]
    movzx edi, r8b
    call .pf_pad
    jmp .pf_strbody
.pf_strleft:
    mov rsi, [rsp+56]
    mov rcx, [rsp+64]
    call .pf_emitstr
    mov ecx, [rsp+40]
    mov edi, ' '
    call .pf_pad
    jmp .pf_loop
.pf_strbody:
    mov rsi, [rsp+56]
    mov rcx, [rsp+64]
    call .pf_emitstr
    jmp .pf_loop
; .pf_pad: ECX copies of EDI. Incs R13 per char. Clobbers RAX/RCX/RDI.
.pf_pad:
    test ecx, ecx
    jz .pp_done
    push rcx
    push rdi
    call putchar
    pop rdi
    pop rcx
    inc r13
    dec ecx
    jmp .pf_pad
.pp_done:
    ret
; .pf_emitstr: RSI=ptr, RCX=len. Incs R13 per char. Clobbers RAX/RDI.
.pf_emitstr:
    test rcx, rcx
    jz .pe_done
    push rsi
    push rcx
    movzx edi, byte [rsi]
    call putchar
    pop rcx
    pop rsi
    inc r13
    inc rsi
    dec rcx
    jnz .pf_emitstr
.pe_done:
    ret
.pf_done:
    mov rax, r13
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; .pf_udiv10: RAX=value, RDI=buf-end-exclusive scratch (20B below RDI).
; Out: RSI=first digit, RCX=len. Clobbers RAX/RDX/RSI/RCX.
.pf_udiv10:
    mov ecx, 10
    lea rsi, [rdi]
.ud_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .ud_loop
    lea rcx, [rdi]
    sub rcx, rsi
    ret
; .pf_uhex: RAX=value, R12=digit table, RDI=buf-end scratch (16B below RDI).
; Out: RSI=first digit, RCX=len (no leading zeros; 0 -> "0").
.pf_uhex:
    lea rsi, [rdi]
    test rax, rax
    jnz .ux_loop
    dec rsi
    mov byte [rsi], '0'
    mov ecx, 1
    ret
.ux_loop:
    mov rdx, rax
    and edx, 0xF
    mov dl, [r12 + rdx]
    dec rsi
    mov [rsi], dl
    shr rax, 4
    jnz .ux_loop
    lea rcx, [rdi]
    sub rcx, rsi
    ret
; .pf_uoct: RAX=value, RDI=buf-end scratch (22B below RDI: 64-bit octal is
; 22 digits max). Out: RSI=first digit, RCX=len (0 -> "0").
.pf_uoct:
    lea rsi, [rdi]
    test rax, rax
    jnz .uo_loop
    dec rsi
    mov byte [rsi], '0'
    mov ecx, 1
    ret
.uo_loop:
    mov rdx, rax
    and edx, 7
    lea rcx, [rel octdig]       ; (no RIP+index form on x86-64: base it)
    mov dl, [rcx + rdx]
    dec rsi
    mov [rsi], dl
    shr rax, 3
    jnz .uo_loop
    lea rcx, [rdi]
    sub rcx, rsi
    ret

; sprintf(RDI=dst, RSI=fmt, ...) -> RAX=count (no bound; always NUL-terminates).
; snprintf(RDI=dst, RSI=n, RDX=fmt, ...) -> RAX=would-be count (C99); writes
; at most n-1 chars + NUL (nothing if n==0, still returns would-be count).
; Same verb set as printf (flags/width/prec/lengths/%o); buffer sink via
; .sp_emit instead of putchar.
; Frame: 5 pushes (40B: entry 8 -> 0) + sub 96 ([rsp,rsp+40) reg spill,
; [rsp+40] width, [rsp+48] prec, [rsp+64] would-be drop counter,
; [rsp+72,rsp+96) 24B numbuf). .sp_emit preserves RCX,RSI,RDI,RDX,R8-R11,
; R14,R15 (touches RAX + flags only), so sequencers keep state in regs:
; R11D=flags (bit0 LEFT, bit1 ZERO, bit2 IS64, bit3 HAS_PREC).
; snprintf spill: RCX,R8,R9 + first two stack args (overall idx 3,4);
; overflow base covers overall idx>=5. Live: RBX=dst cursor, RDI=fmt cursor,
; R12=bound (count incl NUL; -1 unbounded), R13=dst base, R14=idx, R15/R10.
sprintf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov [rsp+0], rdx
    mov [rsp+8], rcx
    mov [rsp+16], r8
    mov [rsp+24], r9
    mov rax, [rsp+144]          ; overall idx 4 = stk0 -> spill[4]
    mov [rsp+32], rax
    mov qword [rsp+64], 0       ; drop counter (would-be math below)
    xor r14d, r14d              ; arg index starts at 0
    lea r15, [rsp]
    lea r10, [rsp+152]          ; overall idx>=5 -> base+(idx-5)*8 (see below)
    mov rbx, rdi                ; dst cursor
    mov r13, rdi                ; dst base
    mov r12, -1                 ; unbounded
    mov rdi, rsi                ; fmt cursor
    jmp sp_run                  ; shared core below (own scope; locals bind here)
snprintf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov [rsp+0], rcx
    mov [rsp+8], r8
    mov [rsp+16], r9
    mov rax, [rsp+144]          ; overall idx 3 = stk0 -> spill[3]
    mov [rsp+24], rax
    mov rax, [rsp+152]          ; overall idx 4 = stk1 -> spill[4]
    mov [rsp+32], rax
    mov qword [rsp+64], 0       ; drop counter
    xor r14d, r14d              ; arg index starts at 0
    lea r15, [rsp]
    lea r10, [rsp+160]          ; overall idx>=5 -> base+(idx-5)*8 (see below)
    mov rbx, rdi                ; dst cursor
    mov r13, rdi                ; dst base
    mov r12, rsi                ; bound n
    mov rdi, rdx                ; fmt cursor
    ; fall through into the shared core below
; Shared sprintf/snprintf core (own scope so both entries share the locals).
; R14 (arg index) starts 0 in both entries (established above); R12=bound,
; R13=base, RBX/RDI cursors.
; NOTE: sp_run MUST sit here on .sp_loop (first executed block). Helpers
; (.sp_emit et al.) live AFTER .sp_done's ret below: entry falling into a
; helper stores garbage and rets into spilled varargs (caught on host).
sp_run:
.sp_loop:
    mov al, [rdi]
    test al, al
    jz .sp_done
    cmp al, '%'
    je .sp_verb
    call .sp_emit
    inc rdi
    jmp .sp_loop
.sp_verb:
    inc rdi                     ; past '%'
    call .sp_adv                ; AL = first spec char (RDI past it)
    jz .sp_pct_end              ; lone trailing %: emit it, stop
    xor r11d, r11d              ; flags
    mov qword [rsp+40], -1      ; width: none
    mov qword [rsp+48], -1      ; prec: none
.sp_flag:
    cmp al, '-'
    jne .sp_fl1
    or r11d, 1
    call .sp_adv
    jz .sp_done
    jmp .sp_flag
.sp_fl1:
    cmp al, '0'
    jne .sp_width
    or r11d, 2
    call .sp_adv
    jz .sp_done
    jmp .sp_flag
.sp_width:
    cmp al, '*'
    jne .sp_wdigits
    call va_next                ; width from arg (negative: LEFT + positive)
    test eax, eax
    jns .sp_wstore
    or r11d, 1
    neg eax
.sp_wstore:
    movsxd rax, eax
    mov [rsp+40], rax
    call .sp_adv
    jz .sp_done
    jmp .sp_prec
.sp_wdigits:
    cmp al, '0'
    jb .sp_prec
    cmp al, '9'
    ja .sp_prec
    xor ecx, ecx
.sp_wloop:
    imul ecx, ecx, 10
    movzx eax, al
    sub eax, '0'
    add ecx, eax
    call .sp_adv
    jz .sp_wdone0
    cmp al, '0'
    jb .sp_wdone
    cmp al, '9'
    ja .sp_wdone
    jmp .sp_wloop
.sp_wdone0:
    movsxd rcx, ecx
    mov [rsp+40], rcx
    jmp .sp_done
.sp_wdone:
    movsxd rcx, ecx
    mov [rsp+40], rcx
.sp_prec:
    cmp al, '.'
    jne .sp_len
    call .sp_adv                ; '.' consumed; bare '.' means prec 0
    jz .sp_pdone0
    mov qword [rsp+48], 0
    or r11d, 8                  ; HAS_PREC
    cmp al, '*'
    jne .sp_pdigits
    call va_next
    test eax, eax
    js .sp_pnone                ; negative prec: none (C99)
    movsxd rax, eax
    mov [rsp+48], rax
    or r11d, 8                  ; HAS_PREC
    call .sp_adv
    jz .sp_done
    jmp .sp_len
.sp_pnone:
    mov qword [rsp+48], -1
    call .sp_adv
    jz .sp_done
    jmp .sp_len
.sp_pdone0:
    mov qword [rsp+48], 0
    jmp .sp_done
.sp_pdigits:
    cmp al, '0'
    jb .sp_len
    cmp al, '9'
    ja .sp_len
    xor ecx, ecx
.sp_ploop:
    imul ecx, ecx, 10
    movzx eax, al
    sub eax, '0'
    add ecx, eax
    call .sp_adv
    jz .sp_pdone0b
    cmp al, '0'
    jb .sp_pdone
    cmp al, '9'
    ja .sp_pdone
    jmp .sp_ploop
.sp_pdone0b:
    movsxd rcx, ecx
    mov [rsp+48], rcx
    jmp .sp_done
.sp_pdone:
    movsxd rcx, ecx
    mov [rsp+48], rcx
    or r11d, 8                  ; HAS_PREC
.sp_len:
    cmp al, 'h'
    jne .sp_l1
    call .sp_adv                ; h/hh accepted, ignored (int slots)
    jz .sp_done
    cmp al, 'h'
    jne .sp_conv
    call .sp_adv
    jz .sp_done
    jmp .sp_conv
.sp_l1:
    cmp al, 'l'
    jne .sp_l2
    or r11d, 4                  ; l/ll: 64-bit value
    call .sp_adv
    jz .sp_done
    cmp al, 'l'
    jne .sp_conv
    call .sp_adv
    jz .sp_done
    jmp .sp_conv
.sp_l2:
    cmp al, 'z'                 ; z: size_t (64-bit here)
    jne .sp_conv
    or r11d, 4
    call .sp_adv
    jz .sp_done
.sp_conv:
    cmp al, '%'
    je .sp_pct
    cmp al, 'c'
    je .sp_c
    cmp al, 's'
    je .sp_s
    cmp al, 'd'
    je .sp_d
    cmp al, 'i'
    je .sp_d
    cmp al, 'u'
    je .sp_u
    cmp al, 'o'
    je .sp_o
    cmp al, 'x'
    je .sp_x
    cmp al, 'X'
    je .sp_X
    cmp al, 'p'
    je .sp_p
    jmp .sp_unknown
.sp_adv:                        ; next fmt char into AL (ZF set on NUL).
    mov al, [rdi]               ; callers follow with `jz .sp_done`
    inc rdi
    test al, al
    ret
.sp_pct:
    test r11d, 2                ; '0' flag: zero pad (C allows %05%)
    jz .sp_pctsp
    mov r8b, '0'
    jmp .sp_pctgo
.sp_pctsp:
    mov r8b, ' '
.sp_pctgo:
    lea rsi, [rel pf_pctch]
    mov rcx, 1
    jmp .sp_stremit
.sp_pct_end:
    mov al, '%'
    call .sp_emit
    jmp .sp_done
.sp_unknown:
    mov rcx, rax                ; stash verb (RCX dead here; emit spares it)
    mov al, '%'
    call .sp_emit
    mov rax, rcx
    call .sp_emit               ; low byte = verb
    jmp .sp_loop
.sp_c:
    call va_next
    mov [rsp+72], al            ; 1-byte body in numbuf scratch
    lea rsi, [rsp+72]
    mov rcx, 1
    mov r8b, ' '                ; '0' ignored for %c
    jmp .sp_stremit
.sp_s:
    call va_next
    test rax, rax
    jnz .sp_s_str
    lea rax, [rel null_str]
.sp_s_str:
    mov rsi, rax
    mov rcx, [rsp+48]           ; prec: max chars (-1: unbounded)
    cmp rcx, -1
    je .sp_s_full
    xor r8d, r8d                ; bounded length count
.sp_s_cap:
    cmp r8, rcx
    jae .sp_s_got
    cmp byte [rsi + r8], 0
    je .sp_s_got
    inc r8
    jmp .sp_s_cap
.sp_s_got:
    mov rcx, r8
    jmp .sp_s_emit
.sp_s_full:
    xor ecx, ecx                ; strlen loop
.sp_s_cnt:
    cmp byte [rsi + rcx], 0
    je .sp_s_emit
    inc rcx
    jmp .sp_s_cnt
.sp_s_emit:
    mov r8b, ' '                ; strings always space-pad
    jmp .sp_stremit
.sp_d:
    call va_next
    test r11d, 4                ; 64-bit value?
    jnz .sp_d64
    movsxd rax, eax             ; C int: low 32, sign-extended
.sp_d64:
    test rax, rax
    jns .sp_dpos
    mov r9b, '-'                ; sign (R9 survives formatting)
    neg rax                     ; magnitude as unsigned (MIN wraps ok)
    jmp .sp_dmag
.sp_dpos:
    xor r9b, r9b
.sp_dmag:
    lea r8, [rsp+96]
    cmp qword [rsp+48], 0       ; prec==0 && value==0 renders empty (C99)
    jne .sp_drender
    test rax, rax
    jz .sp_dempty
.sp_drender:
    call .sp_udiv10
    jmp .sp_numemit
.sp_dempty:
    lea rsi, [r8]
    xor ecx, ecx
    jmp .sp_numemit
.sp_u:
    call va_next
    test r11d, 4
    jnz .sp_u64
    shl rax, 32                 ; C unsigned int: low 32
    shr rax, 32
.sp_u64:
    xor r9b, r9b
    lea r8, [rsp+96]
    cmp qword [rsp+48], 0
    jne .sp_urender
    test rax, rax
    jz .sp_uempty
.sp_urender:
    call .sp_udiv10
    jmp .sp_numemit
.sp_uempty:
    lea rsi, [r8]
    xor ecx, ecx
    jmp .sp_numemit
.sp_o:
    call va_next
    test r11d, 4
    jnz .sp_o64
    shl rax, 32
    shr rax, 32
.sp_o64:
    xor r9b, r9b
    lea r8, [rsp+96]
    cmp qword [rsp+48], 0
    jne .sp_orender
    test rax, rax
    jz .sp_oempty
.sp_orender:
    call .sp_uoct
    jmp .sp_numemit
.sp_oempty:
    lea rsi, [r8]
    xor ecx, ecx
    jmp .sp_numemit
.sp_x:
    call va_next
    test r11d, 4
    jnz .sp_x64
    shl rax, 32
    shr rax, 32
.sp_x64:
    xor r9b, r9b
    lea rdx, [rel hexdig_lo]    ; table in RDX (bound lives in R12!)
    lea r8, [rsp+96]
    cmp qword [rsp+48], 0
    jne .sp_xrender
    test rax, rax
    jz .sp_xempty
.sp_xrender:
    call .sp_uhex
    jmp .sp_numemit
.sp_xempty:
    lea rsi, [r8]
    xor ecx, ecx
    jmp .sp_numemit
.sp_X:
    call va_next
    test r11d, 4
    jnz .sp_X64
    shl rax, 32
    shr rax, 32
.sp_X64:
    xor r9b, r9b
    lea rdx, [rel hexdig_hi]
    lea r8, [rsp+96]
    cmp qword [rsp+48], 0
    jne .sp_Xrender
    test rax, rax
    jz .sp_Xempty
.sp_Xrender:
    call .sp_uhex
    jmp .sp_numemit
.sp_Xempty:
    lea rsi, [r8]
    xor ecx, ecx
    jmp .sp_numemit
.sp_p:
    call va_next                ; full 64-bit value, "0x" + hex
    lea rdx, [rel hexdig_lo]
    lea r8, [rsp+96]
    call .sp_uhex               ; RSI=hex, RCX=hexlen (survive .sp_emit)
    mov rax, [rsp+40]           ; width
    cmp rax, -1
    je .sp_pplain               ; no width: straight "0x"+hex
    sub rax, rcx
    sub rax, 2                  ; pad = width - hexlen - 2
    jbe .sp_pplain
    mov r10d, eax               ; pad (R10 survives .sp_emit)
    test r11d, 1                ; LEFT?
    jnz .sp_pleft
    test r11d, 2                ; ZERO?
    jz .sp_ppadsp
    mov al, '0'                 ; zeros after 0x
    call .sp_emit
    mov al, 'x'
    call .sp_emit
    mov al, '0'
    mov edx, r10d
    call .sp_pad
    jmp .sp_phex
.sp_ppadsp:
    mov al, ' '
    mov edx, r10d
    call .sp_pad
.sp_pplain:
    mov al, '0'
    call .sp_emit
    mov al, 'x'
    call .sp_emit
.sp_phex:
    mov al, [rsi]               ; (RSI/RCX survived prefix emits)
    call .sp_emitloop_entry
    jmp .sp_loop
.sp_pleft:
    mov al, '0'
    call .sp_emit
    mov al, 'x'
    call .sp_emit
    mov al, [rsi]
    call .sp_emitloop_entry
    mov al, ' '
    mov edx, r10d
    call .sp_pad
    jmp .sp_loop
; .sp_numemit: R9B=sign (0/'-'), RSI=digits, RCX=ndigits. Width/prec/ZERO/
; LEFT from stack/flags. (.sp_emit preserves RSI/RCX/R10/R9: state stays
; in regs; pad lives in R10D.)
.sp_numemit:
    mov rax, [rsp+48]           ; prec
    cmp rax, -1
    je .sp_nm_noprec
    sub rax, rcx                ; prec - ndigits
    jbe .sp_nm_noprec
    mov r8d, eax                ; prec zeros (int range)
    jmp .sp_nm_body
.sp_nm_noprec:
    xor r8d, r8d
.sp_nm_body:
    lea rax, [rcx + r8]         ; body = ndigits + preczeros
    test r9b, r9b               ; sign?
    jz .sp_nm_nosign
    inc rax
.sp_nm_nosign:
    mov rdx, [rsp+40]           ; width
    cmp rdx, -1
    je .sp_nm_nowidth
    sub rdx, rax                ; pad = width - body
    ja .sp_nm_padok
.sp_nm_nowidth:
    xor edx, edx
.sp_nm_padok:
    mov r10d, edx               ; pad
    test r11d, 1                ; LEFT?
    jnz .sp_nm_left
    test r11d, 2                ; ZERO (ignored when prec present)?
    jz .sp_nm_padsp
    test r11d, 8                ; HAS_PREC?
    jnz .sp_nm_padsp
    test r9b, r9b               ; zero pad after sign
    jz .sp_nm_zpad
    mov al, r9b
    call .sp_emit
.sp_nm_zpad:
    mov al, '0'
    mov edx, r10d
    call .sp_pad
    jmp .sp_nm_digits
.sp_nm_padsp:
    mov al, ' '
    mov edx, r10d
    call .sp_pad
    test r9b, r9b
    jz .sp_nm_zeros
    mov al, r9b
    call .sp_emit
.sp_nm_zeros:
    mov al, '0'
    mov edx, r8d
    call .sp_pad
.sp_nm_digits:
    call .sp_emitloop_entry     ; RSI/RCX still live
    jmp .sp_loop
.sp_nm_left:
    test r9b, r9b
    jz .sp_nm_lzeros
    mov al, r9b
    call .sp_emit
.sp_nm_lzeros:
    mov al, '0'
    mov edx, r8d
    call .sp_pad
    call .sp_emitloop_entry
    mov al, ' '
    mov edx, r10d
    call .sp_pad
    jmp .sp_loop
; .sp_stremit: R8B=padchar, RSI=ptr, RCX=len. Width pads (LEFT aware).
.sp_stremit:
    mov rax, [rsp+40]           ; width
    cmp rax, -1
    je .sp_strbody
    sub rax, rcx                ; pad = width - len
    jbe .sp_strbody
    mov r10d, eax               ; pad
    test r11d, 1
    jnz .sp_strleft
    mov al, r8b
    mov edx, r10d
    call .sp_pad
    jmp .sp_strbody
.sp_strleft:
    call .sp_emitloop_entry
    mov al, ' '
    mov edx, r10d
    call .sp_pad
    jmp .sp_loop
.sp_strbody:
    call .sp_emitloop_entry
    jmp .sp_loop
; .sp_pad: EDX copies of AL. Preserves ECX/RSI/RDI (digit state stays
; live across pad calls) and all callee-saved (.sp_emit touches RAX+flags).
.sp_pad:
    test edx, edx
    jz .sp_paddone
    call .sp_emit
    dec edx
    jmp .sp_pad
.sp_paddone:
    ret
; .sp_emitloop_entry: emit RSI/RCX (entry point sharing the loop below).
.sp_emitloop_entry:
    test rcx, rcx
    jz .sp_ee_done
.sp_emitloop:
    mov al, [rsi]
    call .sp_emit
    inc rsi
    dec rcx
    jnz .sp_emitloop
.sp_ee_done:
    ret
.sp_done:
    cmp r12, -1
    je .sp_nul
    mov rax, rbx
    sub rax, r13
    cmp rax, r12
    jae .sp_nonul                ; full: no NUL room (C99: still return count)
.sp_nul:
    mov byte [rbx], 0
.sp_nonul:
    mov rax, [r15+64]           ; dropped (R15 base; == [rsp+64] here since no
    add rax, rbx                ; live call, but uniform with .sp_full above)
    sub rax, r13                ; would-be = dropped + stored
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.sp_emit:                       ; AL=char; drops (counted) when bound is full.
    cmp r12, -1                 ; Reachable ONLY via call (never fallthrough:
    je .sp_store                ; snprintf setup falls into sp_run above).
    push rax                    ; save char: the bound math below rebuilds RAX
    mov rax, rbx
    sub rax, r13                ; stored so far
    inc rax                     ; storing one more...
    cmp rax, r12
    pop rax                     ; restore char (pop preserves flags for jae)
    jae .sp_full                ; ...must stay < n (reserve the NUL)
.sp_store:
    mov [rbx], al
    inc rbx
    ret
.sp_full:
    inc qword [r15+64]          ; would-be counter via R15 base: RSP shifts by
    ret                         ; 8 across this call, so [rsp+64] is the wrong
                                ; slot here (numbuf+16); R15==setup RSP always
.sp_udiv10:                      ; R8=buf-end-exclusive (24B below usable)
    lea rsi, [r8]
.ud2_loop:
    xor edx, edx
    mov ecx, 10
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .ud2_loop
    lea rcx, [r8]
    sub rcx, rsi
    ret
.sp_uhex:                        ; R8=buf-end, RDX=digit table
    lea rsi, [r8]
    test rax, rax
    jnz .ux2_loop
    dec rsi
    mov byte [rsi], '0'
    mov ecx, 1
    ret
.ux2_loop:
    mov rcx, rax
    and ecx, 0xF
    mov cl, [rdx + rcx]
    dec rsi
    mov [rsi], cl
    shr rax, 4
    jnz .ux2_loop
    lea rcx, [r8]
    sub rcx, rsi
    ret
.sp_uoct:                         ; R8=buf-end (22B below usable: 64-bit
    lea rsi, [r8]                 ; octal is 22 digits max). RAX=value.
    test rax, rax                 ; Out: RSI=first digit, RCX=len (0->"0").
    jnz .uo2_loop                 ; Preserves RDI (fmt cursor) by contract.
    dec rsi
    mov byte [rsi], '0'
    mov ecx, 1
    ret
.uo2_loop:
    mov rcx, rax
    and ecx, 7
    lea rdx, [rel octdig]         ; (no RIP+index form: base it)
    mov cl, [rdx + rcx]
    dec rsi
    mov [rsi], cl
    shr rax, 3
    jnz .uo2_loop
    lea rcx, [r8]
    sub rcx, rsi
    ret

; exit(RDI=code) — terminate via AH=4Ch (low 8 bits, DOS). Never returns.
exit:
    mov eax, edi
    and eax, 0xFF
    mov ah, 0x4C
    int 0x21
    jmp short $                   ; unreachable: 4Ch from a child always exits
; (end of .text; the .rodata tables live at the top of this file)
