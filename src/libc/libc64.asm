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

section .rodata
null_str: db "(null)",0
hexdig_lo: db "0123456789abcdef"
hexdig_hi: db "0123456789ABCDEF"

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
    mov rax, rcx
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
; Frame: 5 pushes (40B: entry 8 -> 0) + sub 64 ([rsp,rsp+40) reg spill of
; RSI..R9, [rsp+40,rsp+64) 24B numbuf). Live: RBX=fmt, R13=count, R14=idx,
; R15=spill base, R10=overflow base (entry+8 == rsp+112).
printf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov [rsp+0], rsi
    mov [rsp+8], rdx
    mov [rsp+16], rcx
    mov [rsp+24], r8
    mov [rsp+32], r9
    lea r15, [rsp]
    lea r10, [rsp+112]
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
    inc rbx
    mov al, [rbx]
    test al, al
    jz .pf_pct_end              ; lone trailing %: emit it, stop
    inc rbx
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
    cmp al, 'x'
    je .pf_x
    cmp al, 'X'
    je .pf_X
    cmp al, 'p'
    je .pf_p
    jmp .pf_unknown             ; anything else: emit "%<c>" literally
.pf_pct:
    mov edi, '%'
    call putchar
    inc r13
    jmp .pf_loop
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
    movzx edi, al               ; low byte only (C int promotion)
    call putchar
    inc r13
    jmp .pf_loop
.pf_s:
    call va_next
    test rax, rax
    jnz .pf_s_str
    lea rax, [rel null_str]
.pf_s_str:
    mov r12, rax
.pf_s_loop:
    mov al, [r12]
    test al, al
    jz .pf_loop
    movzx edi, al
    call putchar
    inc r13
    inc r12
    jmp .pf_s_loop
.pf_d:
    call va_next                ; %d/%i consume C int: low 32, sign-extended
    movsxd rax, eax             ; (upper vararg bits are undefined per ABI)
    test rax, rax
    jns .pf_num
    mov rcx, rax                ; stash value (putchar spares RCX)
    mov edi, '-'
    call putchar
    inc r13
    mov rax, rcx
    neg rax                     ; wraps fine: magnitude as unsigned
    jmp .pf_num
.pf_u:
    call va_next                ; %u is 32-bit (C unsigned int); %p for 64-bit
    shl rax, 32
    shr rax, 32
    jmp .pf_num
.pf_x:
    call va_next
    shl rax, 32
    shr rax, 32
    lea r12, [rel hexdig_lo]
    jmp .pf_hex
.pf_X:
    call va_next
    shl rax, 32
    shr rax, 32
    lea r12, [rel hexdig_hi]
    jmp .pf_hex
.pf_p:
    call va_next
    mov rcx, rax                ; stash value
    mov edi, '0'
    call putchar
    inc r13
    mov edi, 'x'
    call putchar
    inc r13
    mov rax, rcx
    lea r12, [rel hexdig_lo]
    jmp .pf_hex
.pf_num:                        ; RAX=unsigned value -> decimal via numbuf
    lea rdi, [rsp+64]
    call .pf_udiv10
    jmp .pf_emitbuf
.pf_hex:                        ; RAX=value, R12=digit table -> hex via numbuf
    lea rdi, [rsp+64]
    call .pf_uhex
    jmp .pf_emitbuf
.pf_emitbuf:                    ; RSI=first digit, RCX=len (from formatters)
    test rcx, rcx
    jz .pf_loop
.pf_emitloop:
    movzx edi, byte [rsi]
    call putchar
    inc r13
    inc rsi
    dec rcx
    jnz .pf_emitloop
    jmp .pf_loop
.pf_done:
    mov rax, r13
    add rsp, 64
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

; sprintf(RDI=dst, RSI=fmt, ...) -> RAX=count (no bound; always NUL-terminates).
; snprintf(RDI=dst, RSI=n, RDX=fmt, ...) -> RAX=would-be count (C99); writes
; at most n-1 chars + NUL (nothing if n==0, still returns would-be count).
; Same verb set as printf; buffer sink instead of putchar.
; Frame: 5 pushes (40B: entry 8 -> 0) + sub 80 ([rsp,rsp+40) reg spill,
; [rsp+40,rsp+64) 24B numbuf, [rsp+64] would-be drop counter, [rsp+72] pad).
; snprintf spill: RCX,R8,R9 + first two stack args (overall idx 3,4);
; overflow base covers overall idx>=5. Live: RBX=dst cursor, RDI=fmt cursor,
; R12=bound (count incl NUL; -1 unbounded), R13=dst base, R14=idx, R15/R10.
sprintf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    mov [rsp+0], rdx
    mov [rsp+8], rcx
    mov [rsp+16], r8
    mov [rsp+24], r9
    mov rax, [rsp+128]          ; overall idx 4 = stk0 -> spill[4]
    mov [rsp+32], rax
    mov qword [rsp+64], 0       ; drop counter (would-be math below)
    xor r14d, r14d              ; arg index starts at 0
    lea r15, [rsp]
    lea r10, [rsp+136]          ; overall idx>=5 -> base+(idx-5)*8 (see below)
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
    sub rsp, 80
    mov [rsp+0], rcx
    mov [rsp+8], r8
    mov [rsp+16], r9
    mov rax, [rsp+128]          ; overall idx 3 = stk0 -> spill[3]
    mov [rsp+24], rax
    mov rax, [rsp+136]          ; overall idx 4 = stk1 -> spill[4]
    mov [rsp+32], rax
    mov qword [rsp+64], 0       ; drop counter
    xor r14d, r14d              ; arg index starts at 0
    lea r15, [rsp]
    lea r10, [rsp+144]          ; overall idx>=5 -> base+(idx-5)*8 (see below)
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
    inc rdi
    mov al, [rdi]
    test al, al
    jz .sp_pct_end
    inc rdi
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
    cmp al, 'x'
    je .sp_x
    cmp al, 'X'
    je .sp_X
    cmp al, 'p'
    je .sp_p
    jmp .sp_unknown
.sp_pct:
    mov al, '%'
    call .sp_emit
    jmp .sp_loop
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
    call .sp_emit               ; AL still holds the char (va_next returns it)
    jmp .sp_loop
.sp_s:
    call va_next
    test rax, rax
    jnz .sp_s_str
    lea rax, [rel null_str]
.sp_s_str:
    mov rsi, rax
.sp_s_loop:
    mov al, [rsi]
    test al, al
    jz .sp_loop
    call .sp_emit
    inc rsi
    jmp .sp_s_loop
.sp_d:
    call va_next                ; %d/%i consume C int: low 32, sign-extended
    movsxd rax, eax             ; (upper vararg bits are undefined per ABI)
    test rax, rax
    jns .sp_num
    mov rcx, rax                ; stash value (emit spares RCX)
    mov al, '-'
    call .sp_emit
    mov rax, rcx
    neg rax
    jmp .sp_num
.sp_u:
    call va_next                ; %u is 32-bit (C unsigned int); %p for 64-bit
    shl rax, 32
    shr rax, 32
    jmp .sp_num
.sp_x:
    call va_next
    shl rax, 32
    shr rax, 32
    lea rdx, [rel hexdig_lo]    ; table in RDX (bound lives in R12!)
    jmp .sp_hex
.sp_X:
    call va_next
    shl rax, 32
    shr rax, 32
    lea rdx, [rel hexdig_hi]
    jmp .sp_hex
.sp_p:
    call va_next
    mov rcx, rax                ; stash value
    mov al, '0'
    call .sp_emit
    mov al, 'x'
    call .sp_emit
    mov rax, rcx
    lea rdx, [rel hexdig_lo]
    jmp .sp_hex
.sp_num:                        ; RAX=unsigned value -> decimal via numbuf.
    lea r8, [rsp+64]            ; buf end in R8, NOT RDI: RDI is the live
    call .sp_udiv10             ; format cursor (clobbering it desyncs output)
    jmp .sp_emitbuf
.sp_hex:                        ; RAX=value, RDX=digit table -> hex via numbuf
    lea r8, [rsp+64]            ; (same: RDI must survive number formatting)
    call .sp_uhex
    jmp .sp_emitbuf
.sp_emitbuf:                    ; RSI=first digit, RCX=len (from formatters)
    test rcx, rcx
    jz .sp_loop
.sp_emitloop:
    mov al, [rsi]
    call .sp_emit
    inc rsi
    dec rcx
    jnz .sp_emitloop
    jmp .sp_loop
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
    add rsp, 80
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

; exit(RDI=code) — terminate via AH=4Ch (low 8 bits, DOS). Never returns.
exit:
    mov eax, edi
    and eax, 0xFF
    mov ah, 0x4C
    int 0x21
    jmp short $                   ; unreachable: 4Ch from a child always exits
; (end of .text; the .rodata tables live at the top of this file)
