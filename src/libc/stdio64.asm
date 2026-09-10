; MS-DOS64 stdio64 — C stdio subset over N2 handle syscalls (N3.3).
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
; - 13 FILE64 slots (16 fds minus consoles 0/1/2), 40 B each in BSS.
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

extern memcpy
extern memset
extern malloc
extern realloc
extern free

%define F_INUSE    1
%define F_WRITE    2
%define F_EOF      4
%define F_ERR      8
%define F_DIRTY    16

%define NFILE      13
%define SLURP_CHUNK 4096
%define FLUSH_CHUNK 0x8000

struc FILE64
    .flags: resd 1
    .fd:    resd 1
    .buf:   resq 1
    .cap:   resq 1
    .len:   resq 1
    .pos:   resq 1
endstruc

section .bss
file_table: resb FILE64_size * NFILE

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
; Frame: 4 pushes (32) + sub 8 = 40 (entry 8 -> 0, aligned).
; RBX=dst, R12=size, R13=nmemb, R14=slot.
fread:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rcx
    call file_slot
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
    mov rdx, [r14 + FILE64.len]
    mov rcx, [r14 + FILE64.pos]
    cmp rcx, rdx
    jae .fr_eof                   ; pos >= len: EOF (also covers pos > len:
                                  ; read streams may seek past EOF)
    sub rdx, rcx                  ; avail = len - pos (> 0)
    cmp rax, rdx
    cmova rax, rdx                ; take = min(n, avail) (> 0: both nonzero)
    mov [rsp], rax                ; spill take (frame pad; memcpy takes RAX)
    mov rsi, [r14 + FILE64.buf]
    add rsi, rcx                  ; buf + pos
    mov rdi, rbx
    mov rdx, rax                  ; take
    call memcpy
    mov rcx, [rsp]                ; take
    add [r14 + FILE64.pos], rcx
    mov rax, [r14 + FILE64.len]
    cmp [r14 + FILE64.pos], rax
    jb .fr_items                  ; more data remains: EOF not yet seen
    or dword [r14 + FILE64.flags], F_EOF
.fr_items:
    mov rax, rcx                  ; take
    xor edx, edx
    div r12                       ; RAX = take / size (size != 0: total != 0)
    add rsp, 8
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
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fr_werr:
    or dword [r14 + FILE64.flags], F_ERR
    xor eax, eax
    add rsp, 8
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
    call file_slot
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
    call file_slot                ; RDI=fp still live
    test rax, rax
    jz .fs_neg
    mov r13, rax
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
    call file_slot                ; RDI=fp still live
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
    call file_slot                ; RDI=fp still live
    test rax, rax
    jz .ff_eof
    mov rbx, rax
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
    call file_slot
    test rax, rax
    jz .fc_eof
    mov rbx, rax
    xor r12d, r12d                ; rc = 0
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
    mov rax, r12
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
    call file_slot
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
    call file_slot
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
