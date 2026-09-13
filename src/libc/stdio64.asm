; MS-DOS64 stdio64 — C stdio subset over N2 handle syscalls (N3.3 + N4A.2b).
; Freestanding System V AMD64, NASM -f elf64. Links with libc64.asm (+ crt0
; at N3.4); talks to the kernel EXCLUSIVELY through INT 21h traps, same as
; libc64 (never direct-call kernel code, never link kernel objects).
; Rules (same as libc64.asm): 16 B RSP alignment before every CALL,
; callee-saved RBX/RBP/R12-R15 preserved, DF=0 around rep ops, NEVER use
; the red zone (live IRQs share the current stack — always sub rsp / push
; first; user C code must use -mno-red-zone for the same reason).
; Trap discipline (see idt64 int21_entry: all GPRs restored from the trap
; frame, RAX from the handler-written slot, CF propagated): set EVERY
; volatile arg reg explicitly per call (stale regs are live inputs to some
; handlers — the fd_* helpers below zero RBX/RCX/RSI/RDI/R8-R11 except
; intended args); afterwards ONLY RAX and CF are meaningful — test CF
; FIRST with jc/jnc.
;
; Design (per docs/23 N3.3: static FILE table, read-fully-into-heap, no
; mmap — matches docs/20 §2: NASM's mmap529 becomes slurp-into-heap):
; - 13 FILE64 slots (16 fds minus consoles 0/1/2), 48 B each in BSS.
; - "r" streams EAGERLY slurp the whole file at fopen (4096 B reads via
;   3Fh, exact-fit realloc growth) and CLOSE the fd immediately: fread /
;   fseek / ftell are pure-memory afterwards, and the fd is freed for
;   others. Empty files keep buf=NULL/cap=0 (no wasted block).
; - "w" streams CREATE eagerly at fopen (glibc-like: the truncated file
;   appears at once) and HOLD the fd; fwrite appends to a heap image
;   (exact-fit growth, zero-filled seek gaps); fflush/fclose write the
;   image out sequentially via chunked 40h (fd pos is 0 after create, so
;   no 42h is needed anywhere in this file).
; - Counts are 16-bit on the trap path (handlers mask to CX: 0x10000
;   wraps to 0), so 40h flush uses 0x8000 chunks, slurp 4096 B chunks.
; - Modes: "r" and "w" only (+ trailing "b" tolerated, C89 style). "a" /
;   "r+" / "w+" / "+" return NULL: the kernel has no open-for-write-
;   existing (3Dh denies write modes, 3Ch truncates), so append cannot be
;   honored — failing honestly beats silently truncating user data.
;
; N4A.2b additions (buffered char I/O for the NASM port):
; - FILE64.pb: one-byte pushback (-1 empty, else 0..255). ungetc NEVER
;   touches pos; fgetc/fread drain .pb first, then continue at pos. This
;   matches glibc pushback semantics for both file and console streams.
; - stdin/stdout/stderr objects (F_CONSOLE): stdout/stderr are
;   write-through (fd_write per byte/chunk, no image); stdin reads via
;   fd_read(0) (non-blocking kbd poll: empty poll = EOF, sticky like
;   glibc). fclose on them succeeds without teardown; fseek fails (-1).
; - vfprintf over a real va_list struct walker (GP-only, like printf);
;   fprintf builds the struct and delegates. setvbuf accepts and returns
;   0 (fixed stream policy).

bits 64
default rel

global fopen
global fclose
global fread
global fwrite
global fseek
global ftell
global fflush
global feof
global ferror
global isatty
global fgetc
global getc
global fputc
global putc
global fgets
global fputs
global ungetc
global vfprintf
global fprintf
global setvbuf
global stdin
global stdout
global stderr

extern memcpy
extern memset
extern malloc
extern realloc
extern free
extern null_str                   ; N4A.2b: owned by libc64 (shared tables)
extern hexdig_lo
extern hexdig_hi

%define F_INUSE    1
%define F_WRITE    2
%define F_EOF      4
%define F_ERR      8
%define F_DIRTY    16
%define F_CONSOLE  32

%define NFILE      13
%define SLURP_CHUNK 4096
%define FLUSH_CHUNK 0x8000
%define PB_EMPTY   -1

struc FILE64
    .flags: resd 1
    .fd:    resd 1
    .buf:   resq 1
    .cap:   resq 1
    .len:   resq 1
    .pos:   resq 1
    .pb:    resq 1          ; pushback: -1 empty, else 0..255 (pos untouched)
endstruc

section .bss
file_table: resb FILE64_size * NFILE
stdin_obj: resb FILE64_size
stdout_obj: resb FILE64_size
stderr_obj: resb FILE64_size
std_inited: resb 1
; stdin/stdout/stderr POINTERS (glibc-style FILE* symbols: the objects
; above are FILE64; these hold their addresses once std_init runs).
stdin: resq 1
stdout: resq 1
stderr: resq 1

section .text

; ---- trap helpers (leaf: clobber volatiles only, callee-saved survive) ----
; NOTE: every helper preserves RBX explicitly (push/pop): the trap needs
; RBX=fd on several paths, but callers keep len/slot in RBX across these
; calls (fopen slurp, fflush loop, fclose) — a bare `mov rbx` here was a
; real in-guest test-92 failure (len clobbered to the fd value).
; fd_open(RDI=path) -> RAX=fd, CF. AH=3Dh mode 0 (read-only).
fd_open:
    push rbx
    mov rdx, rdi
    xor ebx, ebx
    xor ecx, ecx
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x3D00
    int 0x21
    pop rbx
    ret

; fd_create(RDI=path) -> RAX=fd, CF. AH=3Ch (truncate/create, attr 0).
fd_create:
    push rbx
    mov rdx, rdi
    xor ebx, ebx
    xor ecx, ecx
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x3C00
    int 0x21
    pop rbx
    ret

; fd_close(RDI=fd) -> CF. AH=3Eh.
fd_close:
    push rbx
    mov rbx, rdi
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x3E00
    int 0x21
    pop rbx
    ret

; fd_read(RDI=fd, RSI=buf, RDX=count16) -> RAX=bytes, CF. AH=3Fh.
fd_read:
    push rbx
    mov rbx, rdi
    mov rcx, rdx
    mov rdx, rsi
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x3F00
    int 0x21
    pop rbx
    ret

; fd_write(RDI=fd, RSI=buf, RDX=count16) -> RAX=bytes, CF. AH=40h.
fd_write:
    push rbx
    mov rbx, rdi
    mov rcx, rdx
    mov rdx, rsi
    xor esi, esi
    xor edi, edi
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov eax, 0x4000
    int 0x21
    pop rbx
    ret

; file_slot(RDI=fp) -> RAX=slot / NULL. Bounds + slot-base + in-use check.
; Clobbers RAX, RCX, RDX, RDI (callers: keep values in callee-saved).
file_slot:
    lea rax, [rel file_table]
    sub rdi, rax
    jc .fs_bad                    ; below table (borrow)
    cmp rdi, FILE64_size * NFILE
    jae .fs_bad                   ; at/past end
    mov rax, rdi
    xor edx, edx
    mov ecx, FILE64_size
    div rcx                       ; RAX=idx, RDX=offset-in-slot (<520: no #DE)
    test edx, edx
    jnz .fs_bad                   ; misaligned: not a slot base
    imul rax, rax, FILE64_size    ; idx*40 (idx < 13: no overflow)
    lea rcx, [rel file_table]
    add rax, rcx
    test dword [rax + FILE64.flags], F_INUSE
    jz .fs_bad                    ; free slot: not a live stream
    ret
.fs_bad:
    xor eax, eax
    ret

; stdio_init() — idempotent console-object init (N4A.2b). Called by crt0
; _start AND lazily by every stdio entry (so the stdin/stdout/stderr
; pointer vars are valid even for programs whose first stdio act reads
; the pointer directly). Preserves RAX/RDI (push/pop); flags clobbered.
global stdio_init
stdio_init:
    push rax
    push rdi
    cmp byte [rel std_inited], 0
    jne .si_done
    lea rax, [rel stdin_obj]
    mov qword [rel stdin], rax
    mov dword [rax + FILE64.flags], F_INUSE | F_CONSOLE
    mov dword [rax + FILE64.fd], 0
    mov qword [rax + FILE64.pb], PB_EMPTY
    lea rax, [rel stdout_obj]
    mov qword [rel stdout], rax
    mov dword [rax + FILE64.flags], F_INUSE | F_WRITE | F_CONSOLE
    mov dword [rax + FILE64.fd], 1
    mov qword [rax + FILE64.pb], PB_EMPTY
    lea rax, [rel stderr_obj]
    mov qword [rel stderr], rax
    mov dword [rax + FILE64.flags], F_INUSE | F_WRITE | F_CONSOLE
    mov dword [rax + FILE64.fd], 2
    mov qword [rax + FILE64.pb], PB_EMPTY
    mov byte [rel std_inited], 1
.si_done:
    pop rdi
    pop rax
    ret

; stream_slot(RDI=fp) -> RAX=slot / NULL. Accepts table slots (via
; file_slot) AND the three console objects. Clobbers RAX, RCX, RDX, RDI.
; Callers must have run stdio_init first (every public entry does).
stream_slot:
    lea rax, [rel stdin_obj]
    cmp rdi, rax
    je .ss_hit
    lea rax, [rel stdout_obj]
    cmp rdi, rax
    je .ss_hit
    lea rax, [rel stderr_obj]
    cmp rdi, rax
    je .ss_hit
    jmp file_slot               ; tail call: contract identical
.ss_hit:
    ret

; fopen(RDI=path, RSI=mode) -> RAX=FILE* / NULL.
; Frame: 4 pushes (32) + sub 24 = 56 (entry 8 -> 0, aligned). Locals:
; [rsp+0]=path, [rsp+8]=fd, [rsp+16]=write-flag. Regs: R13=slot, R12=buf,
; RBX=len, R14=cap.
fopen:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 24
    call stdio_init               ; pointer vars valid even if fopen is first
    mov [rsp+0], rdi
    test rdi, rdi
    jz .fo_null
    test rsi, rsi
    jz .fo_null
    mov al, [rsi]                 ; mode[0]
    cmp al, 'r'
    je .fo_read
    cmp al, 'w'
    jne .fo_null
    mov byte [rsp+16], 1
    jmp .fo_mode1
.fo_read:
    mov byte [rsp+16], 0
.fo_mode1:
    mov al, [rsi+1]               ; mode[1]: NUL or 'b' only (never touch
    test al, al                   ; mode[2] for 1-char modes: "w",0 is only
    jz .fo_mode_ok                ; 2 bytes; [rsi+2] would be the NEXT string
    cmp al, 'b'
    jne .fo_null
    cmp byte [rsi+2], 0           ; "rb"/"wb" must end here ("r+"/junk out)
    jne .fo_null
.fo_mode_ok:
    ; find a free slot
    lea r13, [rel file_table]
    xor r14d, r14d
.fo_find:
    cmp r14, NFILE
    jae .fo_null                  ; table full
    test dword [r13 + FILE64.flags], F_INUSE
    jz .fo_got
    add r13, FILE64_size
    inc r14
    jmp .fo_find
.fo_got:
    mov dword [r13 + FILE64.flags], F_INUSE
    mov dword [r13 + FILE64.fd], -1
    mov qword [r13 + FILE64.buf], 0
    mov qword [r13 + FILE64.cap], 0
    mov qword [r13 + FILE64.len], 0
    mov qword [r13 + FILE64.pos], 0
    mov qword [r13 + FILE64.pb], PB_EMPTY
    cmp byte [rsp+16], 0
    je .fo_do_read
    ; ---- "w": eager CREATE, hold fd ----
    or dword [r13 + FILE64.flags], F_WRITE
    mov rdi, [rsp+0]
    call fd_create
    jc .fo_release                ; create failed (dir full / bad name)
    mov [r13 + FILE64.fd], eax
    mov rax, r13
    add rsp, 24
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fo_do_read:
    ; ---- "r": 3Dh + eager slurp + immediate close ----
    mov rdi, [rsp+0]
    call fd_open
    jc .fo_release                ; missing/unreadable -> NULL
    mov [rsp+8], rax              ; fd
    xor r12d, r12d                ; buf = NULL
    xor ebx, ebx                  ; len = 0
    xor r14d, r14d                ; cap = 0
.fo_slurp:
    mov rax, rbx
    add rax, SLURP_CHUNK          ; need = len + 4096 (no wrap: tiny)
    cmp rax, r14
    jbe .fo_have_room
    mov rdi, r12
    mov rsi, rax
    call realloc                  ; exact-fit growth (files are KBs)
    test rax, rax
    jz .fo_slurp_fail
    mov r12, rax
    mov r14, rbx
    add r14, SLURP_CHUNK          ; cap = len + 4096
.fo_have_room:
    mov rdi, [rsp+8]
    lea rsi, [r12 + rbx]          ; buf + len
    mov edx, SLURP_CHUNK
    call fd_read
    jc .fo_slurp_fail
    add rbx, rax                  ; len += n
    cmp rax, SLURP_CHUNK
    jb .fo_slurp_done             ; short read = EOF
    jmp .fo_slurp
.fo_slurp_done:
    mov rdi, [rsp+8]
    call fd_close                 ; fd served its purpose (errors ignored:
                                  ; the image is complete in memory)
    test rbx, rbx
    jnz .fo_keep
    test r12, r12
    jz .fo_keep
    mov rdi, r12
    call free                     ; empty file: no wasted block
    xor r12d, r12d
    xor r14d, r14d
.fo_keep:
    mov [r13 + FILE64.buf], r12
    mov [r13 + FILE64.cap], r14
    mov [r13 + FILE64.len], rbx
    mov rax, r13
    add rsp, 24
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fo_slurp_fail:
    mov rdi, [rsp+8]
    call fd_close                 ; best-effort (result ignored)
    test r12, r12
    jz .fo_release
    mov rdi, r12
    call free
.fo_release:
    mov dword [r13 + FILE64.flags], 0
.fo_null:
    xor eax, eax
    add rsp, 24
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fread(RDI=ptr, RSI=size, RDX=nmemb, RCX=fp) -> RAX=items (0 at EOF/error).
; Frame: 5 pushes (40) + sub 8 = 48 (entry 8 -> 0, aligned).
; RBX=dst cursor, R12=size, R13=nmemb, R14=slot, R15=delivered bytes,
; [rsp]=remaining bytes.
fread:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rcx
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot
    test rax, rax
    jz .fr_zero                   ; invalid stream
    mov r14, rax
    test dword [r14 + FILE64.flags], F_WRITE
    jnz .fr_werr                  ; write-only stream: honest error, 0 items
    mov rax, r12
    mul r13                       ; RDX:RAX = size*nmemb
    test rdx, rdx
    jnz .fr_zero                  ; overflow: nothing sane to do
    test rax, rax
    jz .fr_zero                   ; zero-size: no-op, flags untouched
    mov [rsp], rax                ; remaining = total
    xor r15d, r15d                ; delivered = 0
    ; drain pushback first (pos untouched, both stream kinds)
    mov rdx, [r14 + FILE64.pb]
    cmp rdx, PB_EMPTY
    je .fr_nopb
    mov [rbx], dl
    mov qword [r14 + FILE64.pb], PB_EMPTY
    inc rbx
    dec qword [rsp]
    inc r15
.fr_nopb:
    cmp qword [rsp], 0
    je .fr_items                  ; whole request was the pushed byte
    test dword [r14 + FILE64.flags], F_CONSOLE
    jnz .fr_cons
    ; ---- file "r": image copy ----
    mov rdx, [r14 + FILE64.len]
    mov rcx, [r14 + FILE64.pos]
    cmp rcx, rdx
    jae .fr_eof                   ; pos >= len: EOF (also covers pos > len:
                                  ; read streams may seek past EOF)
    sub rdx, rcx                  ; avail = len - pos (> 0)
    mov rax, [rsp]                ; remaining
    cmp rax, rdx
    cmova rax, rdx                ; take = min(remaining, avail)
    mov [rsp], rax                ; spill take (memcpy returns dst in RAX)
    mov rsi, [r14 + FILE64.buf]
    add rsi, rcx                  ; buf + pos
    mov rdi, rbx
    mov rdx, rax                  ; take
    call memcpy
    mov rax, [rsp]                ; take (memcpy clobbered RAX)
    add [r14 + FILE64.pos], rax
    add r15, rax                  ; delivered += take
    mov rax, [r14 + FILE64.len]
    cmp [r14 + FILE64.pos], rax
    jb .fr_items                  ; more data remains: EOF not yet seen
    or dword [r14 + FILE64.flags], F_EOF
    jmp .fr_items
.fr_cons:
    ; ---- console (stdin): fd_read loop, 0x8000 chunks ----
    mov rdx, [rsp]                ; remaining
    cmp rdx, FLUSH_CHUNK
    jbe .fr_cchunk
    mov rdx, FLUSH_CHUNK
.fr_cchunk:
    test rdx, rdx
    jz .fr_items
    mov edi, [r14 + FILE64.fd]
    mov rsi, rbx
    call fd_read
    jc .fr_cerr
    test rax, rax
    jz .fr_eof                    ; empty poll: EOF (sticky, like glibc)
    add rbx, rax
    add r15, rax
    sub [rsp], rax
    cmp rax, rdx
    jb .fr_eof                    ; short read: EOF
    cmp qword [rsp], 0
    jne .fr_cons
    jmp .fr_items
.fr_cerr:
    or dword [r14 + FILE64.flags], F_ERR
    jmp .fr_items
.fr_items:
    mov rax, r15                  ; delivered bytes
    xor edx, edx
    div r12                       ; RAX = delivered / size (size != 0)
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fr_eof:
    or dword [r14 + FILE64.flags], F_EOF
.fr_zero:
    xor eax, eax
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fr_werr:
    or dword [r14 + FILE64.flags], F_ERR
    xor eax, eax
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fwrite(RDI=ptr, RSI=size, RDX=nmemb, RCX=fp) -> RAX=items (0 on error).
; Same frame as fread. RBX=src, R12=size, R13=nmemb, R14=slot.
fwrite:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rcx
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot
    test rax, rax
    jz .fw_zero                   ; invalid stream
    mov r14, rax
    test dword [r14 + FILE64.flags], F_WRITE
    jz .fw_rerr                   ; read-only stream: honest error, 0 items
    mov rax, r12
    mul r13                       ; total = size*nmemb
    test rdx, rdx
    jnz .fw_rerr                  ; overflow
    test rax, rax
    jz .fw_zero                   ; zero-size: no-op success (0 items, no dirt)
    test dword [r14 + FILE64.flags], F_CONSOLE
    jnz .fw_cons                  ; console: write-through, no image
    mov rcx, [r14 + FILE64.pos]
    add rcx, rax                  ; need = pos + total (tiny: no wrap)
    jc .fw_rerr
    cmp rcx, [r14 + FILE64.cap]
    jbe .fw_room
    mov [rsp], rax                ; spill total across realloc (frame pad)
    mov rdi, [r14 + FILE64.buf]
    mov rsi, rcx                  ; need
    call realloc                  ; exact-fit growth
    mov rcx, [rsp]                ; total (realloc clobbers volatiles)
    test rax, rax
    jz .fw_rerr                   ; growth failed: nothing written
    mov [r14 + FILE64.buf], rax
    add rcx, [r14 + FILE64.pos]   ; need = total + pos
    mov [r14 + FILE64.cap], rcx
.fw_room:
    mov rax, r12
    mul r13                       ; RAX = total (no overflow: checked above)
    mov [rsp], rax                ; spill total across memcpy
    mov rdx, rax
    mov rdi, [r14 + FILE64.buf]
    add rdi, [r14 + FILE64.pos]
    mov rsi, rbx                  ; src
    call memcpy
    mov rax, [rsp]                ; total
    add [r14 + FILE64.pos], rax
    mov rdx, [r14 + FILE64.len]
    cmp [r14 + FILE64.pos], rdx
    jbe .fw_dirty
    mov rdx, [r14 + FILE64.pos]
    mov [r14 + FILE64.len], rdx
.fw_dirty:
    or dword [r14 + FILE64.flags], F_DIRTY
    mov rax, r13                  ; all nmemb accepted
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fw_cons:
    ; ---- console (stdout/stderr): fd_write loop, 0x8000 chunks ----
    mov [rsp], rax                ; remaining = total
.fw_cloop:
    mov rdx, [rsp]
    test rdx, rdx
    jz .fw_citems
    cmp rdx, FLUSH_CHUNK
    jbe .fw_cchunk
    mov rdx, FLUSH_CHUNK
.fw_cchunk:
    mov edi, [r14 + FILE64.fd]
    mov rsi, rbx
    call fd_write                 ; (RDI=fd, RSI=buf, RDX=count16)
    jc .fw_cerr
    test rax, rax
    jz .fw_cerr                   ; zero progress: treat as error
    add rbx, rax
    sub [rsp], rax
    cmp rax, rdx
    jb .fw_cerr                   ; short write: error, keep partial count
    jmp .fw_cloop
.fw_cerr:
    or dword [r14 + FILE64.flags], F_ERR
.fw_citems:
    mov rax, r12
    mul r13                       ; RAX = total (no overflow: checked)
    sub rax, [rsp]                ; delivered bytes
    xor edx, edx
    div r12                       ; items = delivered / size
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fw_zero:
    xor eax, eax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fw_rerr:
    or dword [r14 + FILE64.flags], F_ERR
    xor eax, eax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fseek(RDI=fp, RSI=offset, RDX=whence) -> RAX=0 / -1.
; Frame: 3 pushes = 24 (entry 8 -> 0, aligned). RBX=offset, R12=whence,
; R13=slot.
fseek:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdx
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot                ; RDI=fp still live
    test rax, rax
    jz .fs_neg
    mov r13, rax
    test dword [r13 + FILE64.flags], F_CONSOLE
    jnz .fs_neg                   ; console: not seekable (ESPIPE-honest)
    cmp r12, 2
    ja .fs_neg                    ; whence > 2 (negatives are huge: ja works)
    je .fs_end
    test r12, r12
    jz .fs_set
    mov rax, [r13 + FILE64.pos]   ; SEEK_CUR
    jmp .fs_add
.fs_end:
    mov rax, [r13 + FILE64.len]   ; SEEK_END
    jmp .fs_add
.fs_set:
    xor eax, eax                  ; SEEK_SET
.fs_add:
    add rax, rbx                  ; newpos = base + offset (signed)
    jo .fs_neg
    test rax, rax
    js .fs_neg                    ; negative position
    test dword [r13 + FILE64.flags], F_WRITE
    jz .fs_store                  ; read stream: any pos >= 0 ok (past EOF
                                  ; reads as EOF; no buffer to extend)
    cmp rax, [r13 + FILE64.len]
    jbe .fs_store
    ; write stream past EOF: grow + zero-fill the gap (C: gap reads zero)
    mov r12, rax                  ; newpos (whence no longer needed)
    mov rdi, [r13 + FILE64.buf]
    mov rsi, r12
    call realloc
    test rax, rax
    jz .fs_neg
    mov rcx, [r13 + FILE64.len]   ; gap start = old len
    mov rdx, r12
    sub rdx, rcx                  ; gap length (> 0: newpos > len)
    mov [r13 + FILE64.buf], rax
    mov [r13 + FILE64.cap], r12
    mov [r13 + FILE64.len], r12
    mov rdi, rax
    add rdi, rcx                  ; buf + old len
    xor esi, esi                  ; fill byte 0 (RDX = gap length survives:
                                  ; only stores ran since the sub)
    call memset
    mov rax, r12                  ; newpos
    or dword [r13 + FILE64.flags], F_DIRTY
.fs_store:
    mov [r13 + FILE64.pos], rax
    mov qword [r13 + FILE64.pb], PB_EMPTY  ; seek discards pushback (C99)
    and dword [r13 + FILE64.flags], ~F_EOF  ; successful seek clears EOF
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.fs_neg:
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

; ftell(RDI=fp) -> RAX=position / -1.
ftell:
    push rbx                      ; 1 push = 8 (entry 8 -> 0, aligned)
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot                ; RDI=fp still live
    test rax, rax
    jz .ft_neg
    mov rax, [rax + FILE64.pos]
    pop rbx
    ret
.ft_neg:
    mov rax, -1
    pop rbx
    ret

; fflush(RDI=fp) -> RAX=0 / EOF(-1). Write streams: chunked 40h of the
; whole image (fd pos is 0 after create: sequential writes land at 0..len).
; Read streams: no-op success. Frame: 4 pushes (32) + sub 8 = 40 (entry
; 8 -> 0, aligned). RBX=slot, R12=remaining, R13=cursor, R14=chunk.
fflush:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot                ; RDI=fp still live
    test rax, rax
    jz .ff_eof
    mov rbx, rax
    test dword [rbx + FILE64.flags], F_CONSOLE
    jz .ff_file                   ; file streams below; consoles: no-op
    xor eax, eax                  ; write-through: nothing buffered
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.ff_file:
    test dword [rbx + FILE64.flags], F_WRITE
    jz .ff_ok                     ; read stream: nothing to flush
    test dword [rbx + FILE64.flags], F_DIRTY
    jz .ff_ok                     ; clean: nothing to flush
    mov r12, [rbx + FILE64.len]
    mov r13, [rbx + FILE64.buf]
.ff_loop:
    test r12, r12
    jz .ff_clean
    mov rdx, FLUSH_CHUNK
    cmp r12, rdx
    jae .ff_have_n
    mov rdx, r12                  ; last chunk: the remainder
.ff_have_n:
    mov r14, rdx                  ; chunk (fd_write returns count in RAX)
    mov edi, [rbx + FILE64.fd]
    mov rsi, r13
    call fd_write
    jc .ff_err
    cmp rax, r14
    jne .ff_err                   ; short write: disk full or media error
    add r13, rax
    sub r12, rax
    jmp .ff_loop
.ff_clean:
    and dword [rbx + FILE64.flags], ~F_DIRTY
.ff_ok:
    xor eax, eax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.ff_err:
    or dword [rbx + FILE64.flags], F_ERR
.ff_eof:
    mov rax, -1
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fclose(RDI=fp) -> RAX=0 / EOF(-1). Flushes dirty write streams, closes
; held fds, frees the image, clears the slot — teardown always runs, even
; when the flush fails (C: resources released; EOF reported).
; Frame: 4 pushes (32) + sub 8 = 40 (entry 8 -> 0, aligned).
; RBX=slot, R12=rc, R13=fp, R14=spare.
fclose:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r13, rdi
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot
    test rax, rax
    jz .fc_eof
    mov rbx, rax
    xor r12d, r12d                ; rc = 0
    test dword [rbx + FILE64.flags], F_CONSOLE
    jnz .fc_con                   ; console: no teardown, stays usable
    test dword [rbx + FILE64.flags], F_WRITE
    jz .fc_free                   ; read stream: no fd held, image only
    test dword [rbx + FILE64.flags], F_DIRTY
    jz .fc_close
    mov rdi, r13
    call fflush
    test rax, rax
    jz .fc_close
    mov r12, -1                   ; flush failed: report EOF after teardown
.fc_close:
    mov edi, [rbx + FILE64.fd]
    call fd_close
    jc .fc_closefail
    jmp .fc_free
.fc_closefail:
    mov r12, -1
.fc_free:
    mov rdi, [rbx + FILE64.buf]
    call free                     ; NULL-safe
    mov dword [rbx + FILE64.flags], 0
    mov dword [rbx + FILE64.fd], -1
    mov qword [rbx + FILE64.buf], 0
    mov qword [rbx + FILE64.cap], 0
    mov qword [rbx + FILE64.len], 0
    mov qword [rbx + FILE64.pos], 0
    mov qword [rbx + FILE64.pb], PB_EMPTY
    mov rax, r12
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fc_con:
    mov rax, r12                  ; console close: success no-op (rc = 0)
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fc_eof:
    mov rax, -1
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; feof(RDI=fp) -> RAX != 0 at EOF (invalid stream: 0).
feof:
    push rbx
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot
    test rax, rax
    jz .fe_no
    test dword [rax + FILE64.flags], F_EOF
    jz .fe_no
    mov eax, 1
    pop rbx
    ret
.fe_no:
    xor eax, eax
    pop rbx
    ret

; ferror(RDI=fp) -> RAX != 0 on error (invalid stream: 1 — asking is wrong).
ferror:
    push rbx
    call stdio_init               ; console objects live (preserves RDI)
    call stream_slot
    test rax, rax
    jz .fe_yes
    test dword [rax + FILE64.flags], F_ERR
    jz .fe_no2
.fe_yes:
    mov eax, 1
    pop rbx
    ret
.fe_no2:
    xor eax, eax
    pop rbx
    ret

; isatty(RDI=fd) -> RAX=1 for console handles 0/1/2, else 0 (honest: DOS
; handles 0-2 ARE the console; files never are). Leaf, no stack use.
isatty:
    cmp rdi, 2
    jbe .it_yes
    xor eax, eax
    ret
.it_yes:
    mov eax, 1
    ret

; ------------------------------------------------------------
; N4A.2b char I/O + formatted output (buffered over the same streams).
; ------------------------------------------------------------

; stream_putc(RDI=char-low-byte, RSI=slot) -> RAX=0 ok / -1 err.
; Local helper (not global): file "w" appends to the image, console
; writes through via fd_write. Sets F_ERR on failure. Clobbers RAX,
; RCX, RDX, RDI, RSI.
stream_putc:
    test dword [rsi + FILE64.flags], F_WRITE
    jz .spc_err                   ; read-only stream
    test dword [rsi + FILE64.flags], F_CONSOLE
    jnz .spc_con
    ; file "w": grow + append (mirrors fwrite, single byte)
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8                    ; 4 pushes + 8 = 40 (entry 8 -> 0)
    mov rbx, rsi                  ; slot
    mov r12b, dil                 ; char
    mov rcx, [rbx + FILE64.pos]
    inc rcx                       ; need = pos + 1
    cmp rcx, [rbx + FILE64.cap]
    jbe .spc_room
    mov rdi, [rbx + FILE64.buf]
    mov rsi, rcx
    call realloc
    test rax, rax
    jz .spc_rerr
    mov [rbx + FILE64.buf], rax
    mov [rbx + FILE64.cap], rcx
.spc_room:
    mov rax, [rbx + FILE64.buf]
    add rax, [rbx + FILE64.pos]
    mov cl, r12b
    mov [rax], cl
    inc qword [rbx + FILE64.pos]
    mov rdx, [rbx + FILE64.len]
    cmp [rbx + FILE64.pos], rdx
    jbe .spc_dirty
    mov rdx, [rbx + FILE64.pos]
    mov [rbx + FILE64.len], rdx
.spc_dirty:
    or dword [rbx + FILE64.flags], F_DIRTY
    xor eax, eax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.spc_rerr:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
.spc_err:
    or dword [rsi + FILE64.flags], F_ERR
    mov rax, -1
    ret
.spc_con:
    push rbx
    push r12                      ; 2 pushes + sub 8 = 24 (entry 8 -> 0)
    sub rsp, 8
    mov [rsp], dil                ; 1-byte buffer
    mov ebx, [rsi + FILE64.fd]
    mov r12, rsi                  ; slot (fd_write spares R12? NO — it
                                  ; preserves RBX only. Reload below.)
    mov edi, ebx
    lea rsi, [rsp]
    mov rdx, 1
    call fd_write
    mov rsi, r12
    jc .spc_cerr
    cmp rax, 1
    jne .spc_cerr
    xor eax, eax
    add rsp, 8
    pop r12
    pop rbx
    ret
.spc_cerr:
    add rsp, 8
    pop r12
    pop rbx
    jmp .spc_err                  ; (RSI=slot still live)

; stream_getc(RSI=slot) -> RAX=char (0..255) / -1 EOF-or-error.
; Drains .pb first (pos untouched), then image (file "r") or fd_read(0).
; Sets F_EOF on end / F_ERR on trap failure. Clobbers RAX, RCX, RDX, RDI.
stream_getc:
    test dword [rsi + FILE64.flags], F_WRITE
    jnz .sgc_err                  ; write-only stream
    mov rax, [rsi + FILE64.pb]
    cmp rax, PB_EMPTY
    je .sgc_nopb
    mov qword [rsi + FILE64.pb], PB_EMPTY
    and eax, 0xFF                 ; (pos untouched by design)
    ret
.sgc_nopb:
    test dword [rsi + FILE64.flags], F_CONSOLE
    jnz .sgc_con
    mov rdx, [rsi + FILE64.len]
    mov rcx, [rsi + FILE64.pos]
    cmp rcx, rdx
    jae .sgc_eof
    mov rax, [rsi + FILE64.buf]
    movzx eax, byte [rax + rcx]
    inc qword [rsi + FILE64.pos]
    cmp qword [rsi + FILE64.pos], rdx
    jb .sgc_ret
    or dword [rsi + FILE64.flags], F_EOF
.sgc_ret:
    ret
.sgc_con:
    push rbx
    push r12                      ; 2 pushes + sub 8 = 24 (entry 8 -> 0)
    sub rsp, 8
    mov ebx, [rsi + FILE64.fd]
    mov r12, rsi
    mov edi, ebx
    lea rsi, [rsp]
    mov rdx, 1
    call fd_read
    mov rsi, r12
    jc .sgc_cerr
    test rax, rax
    jz .sgc_ceof
    movzx eax, byte [rsp]
    add rsp, 8
    pop r12
    pop rbx
    ret
.sgc_ceof:
    add rsp, 8
    pop r12
    pop rbx
.sgc_eof:
    or dword [rsi + FILE64.flags], F_EOF
    mov rax, -1
    ret
.sgc_cerr:
    add rsp, 8
    pop r12
    pop rbx
.sgc_err:
    or dword [rsi + FILE64.flags], F_ERR
    mov rax, -1
    ret

; fgetc(RDI=fp) -> RAX=char / EOF(-1).
fgetc:
    push rbx                      ; 1 push (entry 8 -> 0, aligned)
    call stdio_init
    call stream_slot              ; RDI=fp still live
    test rax, rax
    jz .fg_eof
    mov rsi, rax
    call stream_getc
    pop rbx
    ret
.fg_eof:
    mov rax, -1
    pop rbx
    ret

; getc(RDI=fp) — identical to fgetc (provided as a function; no headers
; exist yet to make it a macro).
getc:
    jmp fgetc

; fputc(RDI=c, RSI=fp) -> RAX=c / EOF(-1).
fputc:
    push rbx                      ; 1 push (entry 8 -> 0, aligned)
    mov ebx, edi                  ; char (stream_slot takes RDI=fp)
    mov rdi, rsi
    call stdio_init
    call stream_slot              ; RDI=fp still live
    test rax, rax
    jz .fp_eof
    mov rsi, rax
    mov rdi, rbx
    call stream_putc
    test rax, rax
    jnz .fp_eof
    mov eax, ebx
    and eax, 0xFF
    pop rbx
    ret
.fp_eof:
    mov rax, -1
    pop rbx
    ret

; putc(RDI=c, RSI=fp) — identical to fputc.
putc:
    jmp fputc

; fputs(RDI=s, RSI=fp) -> RAX=0 ok / EOF(-1). NULL s fails honestly.
fputs:
    push rbx
    push r12                      ; 2 pushes (entry 8 -> 0, aligned)
    test rdi, rdi
    jz .fs_null
    mov rbx, rdi                  ; s cursor
    mov r12, rsi                  ; fp
    mov rdi, rsi
    call stdio_init
    mov rdi, r12
    call stream_slot
    test rax, rax
    jz .fs_null
    mov r12, rax                  ; slot
.fs_loop:
    mov al, [rbx]
    test al, al
    jz .fs_ok
    movzx edi, al
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .fs_null
    inc rbx
    jmp .fs_loop
.fs_ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.fs_null:
    mov rax, -1
    pop r12
    pop rbx
    ret

; fgets(RDI=buf, RSI=n, RDX=fp) -> RAX=buf / NULL (n<=0, invalid, or
; immediate EOF). Reads at most n-1 chars, stops after '\n'.
; Frame: 5 pushes (40) + sub 8 = 48 (entry 8 -> 0, aligned).
; RBX=dst cursor, R12=n, R13=remaining, R14=slot, R15=buf orig.
fgets:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    cmp rsi, 0
    jle .fg_null                  ; n <= 0: store nothing
    mov rbx, rdi
    mov r15, rdi                  ; buf orig
    mov r12, rsi
    mov rdi, rdx
    call stdio_init
    call stream_slot              ; RDI=fp still live
    test rax, rax
    jz .fg_null
    mov r14, rax
    lea r13, [r12 - 1]            ; room for NUL
.fg_loop:
    test r13, r13
    jz .fg_term
    mov rsi, r14
    call stream_getc
    cmp rax, -1
    je .fg_end
    mov [rbx], al
    inc rbx
    dec r13
    cmp al, 10                    ; '\n': stop after storing
    je .fg_term
    jmp .fg_loop
.fg_term:
    mov byte [rbx], 0
    mov rax, r15
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fg_end:
    cmp rbx, r15
    jne .fg_term                  ; chars read: NUL + return buf
.fg_null:
    xor eax, eax
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ungetc(RDI=c, RSI=fp) -> RAX=c / EOF(-1). One byte only (a pending
; pushback fails); write streams fail. pos is NEVER touched (drain order
; gives pushback precedence; fseek clears it).
ungetc:
    push rbx                      ; 1 push (entry 8 -> 0, aligned)
    mov ebx, edi                  ; char
    mov rdi, rsi
    call stdio_init
    call stream_slot              ; RDI=fp still live
    test rax, rax
    jz .ug_eof
    test dword [rax + FILE64.flags], F_WRITE
    jnz .ug_eof
    cmp qword [rax + FILE64.pb], PB_EMPTY
    jne .ug_eof                   ; one-byte guarantee
    and ebx, 0xFF
    mov [rax + FILE64.pb], rbx
    mov rax, rbx
    pop rbx
    ret
.ug_eof:
    mov rax, -1
    pop rbx
    ret

; vf_next: local va_list walker (GP-only, like the printf family).
; R15 = 24 B va copy base ([+0]=gp_off dword, [+8]=overflow ptr,
; [+16]=reg_save ptr). GP slots are 8 bytes apart: full qword loads,
; 32-bit verbs use the low half (C int promotion). Out: RAX=value.
; Clobbers RAX, RCX.
vf_next:
    mov ecx, [r15]                ; gp_offset
    cmp ecx, 48
    jae .vn_ovf
    mov rax, [r15 + 16]           ; reg_save_area
    mov rax, [rax + rcx]
    add dword [r15], 8
    ret
.vn_ovf:
    mov rcx, [r15 + 8]            ; overflow_arg_area
    mov rax, [rcx]
    add qword [r15 + 8], 8
    ret

; vfprintf(RDI=fp, RSI=fmt, RDX=ap) -> RAX=chars / -1 on stream error.
; Verbs: bare {d,i,u,x,X,p,s,c,%} (same set + semantics as printf:
; d/i/u/x/X are C int 32-bit, p is 64-bit, s NULL renders "(null)").
; Frame: 5 pushes (40) + sub 48 (88: entry 8 -> 0, aligned).
; [rsp+0..24) = va copy, [rsp+24..48) = 24 B numbuf (end at [rsp+48]).
; Live: RBX=fmt cursor, R12=slot, R13=count, R14=digit table, R15=va base.
vfprintf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rsi                  ; fmt (save across stdio_init: callee-saved)
    mov r12, rdi                  ; fp
    mov r14, rdx                  ; ap (struct ptr)
    mov rdi, r12
    call stdio_init
    mov rdi, r12
    call stream_slot
    test rax, rax
    jz .vf_err0
    mov r12, rax                  ; slot
    mov rax, [r14]                ; copy the 24 B va_list struct
    mov [rsp + 0], rax
    mov rax, [r14 + 8]
    mov [rsp + 8], rax
    mov rax, [r14 + 16]
    mov [rsp + 16], rax
    lea r15, [rsp]                ; va base for vf_next
    xor r13d, r13d                ; count
.vf_loop:
    mov al, [rbx]
    test al, al
    jz .vf_done
    cmp al, '%'
    je .vf_verb
    movzx edi, al
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    inc rbx
    jmp .vf_loop
.vf_verb:
    inc rbx
    mov al, [rbx]
    test al, al
    jz .vf_pct_end
    inc rbx
    cmp al, '%'
    je .vf_pct
    cmp al, 'c'
    je .vf_c
    cmp al, 's'
    je .vf_s
    cmp al, 'd'
    je .vf_d
    cmp al, 'i'
    je .vf_d
    cmp al, 'u'
    je .vf_u
    cmp al, 'x'
    je .vf_x
    cmp al, 'X'
    je .vf_X
    cmp al, 'p'
    je .vf_p
    jmp .vf_unknown
.vf_pct:
    mov edi, '%'
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    jmp .vf_loop
.vf_pct_end:
    mov edi, '%'
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    jmp .vf_done
.vf_unknown:
    mov r14, rax                  ; stash verb (R14 free here; putc spares it)
    mov edi, '%'
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    mov rax, r14
    movzx edi, al
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    jmp .vf_loop
.vf_c:
    call vf_next
    movzx edi, al
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    jmp .vf_loop
.vf_s:
    call vf_next
    test rax, rax
    jnz .vf_s_str
    lea rax, [rel null_str]
.vf_s_str:
    mov r14, rax
.vf_s_loop:
    mov al, [r14]
    test al, al
    jz .vf_loop
    movzx edi, al
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    inc r14
    jmp .vf_s_loop
.vf_d:
    call vf_next
    movsxd rax, eax               ; C int, sign-extended
    test rax, rax
    jns .vf_num
    mov r14, rax                  ; stash (putc spares R14)
    mov edi, '-'
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    mov rax, r14
    neg rax
    jmp .vf_num
.vf_u:
    call vf_next
    shl rax, 32
    shr rax, 32
    jmp .vf_num
.vf_x:
    call vf_next
    shl rax, 32
    shr rax, 32
    lea r14, [rel hexdig_lo]
    jmp .vf_hex
.vf_X:
    call vf_next
    shl rax, 32
    shr rax, 32
    lea r14, [rel hexdig_hi]
    jmp .vf_hex
.vf_p:
    call vf_next
    mov r14, rax
    mov edi, '0'
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    mov edi, 'x'
    mov rsi, r12
    call stream_putc
    test rax, rax
    jnz .vf_err
    inc r13
    mov rax, r14
    lea r14, [rel hexdig_lo]
    jmp .vf_hex
.vf_num:
    lea rdi, [rsp + 48]
    call .vf_udiv10
    jmp .vf_emitbuf
.vf_hex:
    lea rdi, [rsp + 48]
    call .vf_uhex
    jmp .vf_emitbuf
.vf_emitbuf:                      ; RSI=first digit, RCX=len
    test rcx, rcx
    jz .vf_loop
.vf_emitloop:
    movzx edi, byte [rsi]
    push rsi                      ; stash across stream_putc (stack, not the
    push rcx                      ; live numbuf region below [rsp+48))
    mov rsi, r12
    call stream_putc
    pop rcx
    pop rsi
    test rax, rax
    jnz .vf_err
    inc r13
    inc rsi
    dec rcx
    jnz .vf_emitloop
    jmp .vf_loop
.vf_done:
    mov rax, r13
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.vf_err:
    mov rax, -1
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.vf_err0:
    mov rax, -1
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; .vf_udiv10: RAX=value, RDI=buf-end-exclusive (20B usable below RDI).
; Out: RSI=first digit, RCX=len. Clobbers RAX/RDX/RSI/RCX.
.vf_udiv10:
    mov ecx, 10
    lea rsi, [rdi]
.vf_ud_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .vf_ud_loop
    lea rcx, [rdi]
    sub rcx, rsi
    ret
; .vf_uhex: RAX=value, R14=digit table, RDI=buf-end (16B usable below).
; Out: RSI=first digit, RCX=len. Clobbers RAX/RDX/RSI/RCX.
.vf_uhex:
    lea rsi, [rdi]
    test rax, rax
    jnz .vf_ux_loop
    dec rsi
    mov byte [rsi], '0'
    mov ecx, 1
    ret
.vf_ux_loop:
    mov rdx, rax
    and edx, 0xF
    mov dl, [r14 + rdx]
    dec rsi
    mov [rsi], dl
    shr rax, 4
    jnz .vf_ux_loop
    lea rcx, [rdi]
    sub rcx, rsi
    ret

; fprintf(RDI=fp, RSI=fmt, ...) -> RAX=chars / -1. Builds a va_list struct
; and delegates to vfprintf (single format core, no duplication).
; Frame: 2 pushes (16) + sub 72 (88: entry 8 -> 0, aligned).
; [rsp+0..24) = va struct (gp,fp,overflow,reg_save), [rsp+24..72) = 48 B
; reg_save_area (RDX,RCX,R8,R9 + zero pad). RBX=fp, R12=fmt.
fprintf:
    push rbx
    push r12
    sub rsp, 72
    mov rbx, rdi
    mov r12, rsi
    mov [rsp + 24], rdx
    mov [rsp + 32], rcx
    mov [rsp + 40], r8
    mov [rsp + 48], r9
    mov qword [rsp + 56], 0
    mov qword [rsp + 64], 0
    mov dword [rsp + 0], 0        ; gp_offset: varargs start at reg_save[0]
    mov dword [rsp + 4], 48       ; fp_offset: no FP varargs (GP-only verbs)
    mov rax, [rsp + 96]           ; stk0 = [E+8] (E = rsp+88)
    mov [rsp + 8], rax            ; overflow_arg_area
    lea rax, [rsp + 24]
    mov [rsp + 16], rax           ; reg_save_area
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rsp]
    call vfprintf                 ; RAX passes straight through
    add rsp, 72
    pop r12
    pop rbx
    ret

; setvbuf(RDI=fp, RSI=buf, RDX=mode, RCX=size) -> RAX=0 ok / EOF(-1).
; Honest stub: stream policy is fixed (slurp/write-image/write-through),
; all modes accepted, buf ignored. Validates the stream only.
setvbuf:
    push rbx                      ; 1 push (entry 8 -> 0, aligned)
    call stdio_init
    call stream_slot              ; RDI=fp still live
    test rax, rax
    jz .sv_eof
    xor eax, eax
    pop rbx
    ret
.sv_eof:
    mov rax, -1
    pop rbx
    ret
