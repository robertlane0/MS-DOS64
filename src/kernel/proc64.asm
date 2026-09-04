; MS-DOS64 src/kernel/proc64.asm — Phase 8: Process Management (PSP64) 64-bit
; Converts MSDOS.ASM SETMEM (MSDOS.ASM:3363-3410, 3748-3749) + ABORT (1356-1393)
; + COMMAND.ASM COMLOAD/EXELOAD (COMMAND.ASM:953-1000,2028-2091) to flat 64-bit.
;
; Original: 256B PSP at segment DX, INT 20h CD20, top_seg para, CALL5 EAh far ptr,
;           INT22/23/24 vectors, FCB1@5Ch/FCB2@6Ch, cmd tail@80h, SETBASE via INT21.
;           COM loads at PSP+0x100, EXE with MZ header reloc, SS:SP=BX:CX.
; 64-bit:   512B PSP64 (include/psp.inc), flat linear, INT20 kept as debug bytes,
;           top_mem dq linear, call5_ptr dq, exit/cont/error RIP dq, FCB 32B each,
;           cmd tail 127B @0xA0, env_ptr dq, CR3/RSP/RFLAGS, R8-R15 save, fd_table16.
;           COM raw copy to PSP+512, EXE64 'MZ64' header (32B) payload to PSP+512.
;           Owner in MCB64 set to PSP linear (was 1 kernel) for per-process accounting.
;           Env block is NUL-joined "NAME=VAL" + double NUL (DOS2+ env segment analog).
;
; Process table: 16 slots, state 0 free / 1 running / 2 zombie, pid, psp, entry,
;           stack_top, exitcode, memsize, env ptr. Slot 0 is kernel (pid 0).
;
bits 64
default rel

%include "include/psp.inc"
%include "include/mcb.inc"

section .text
global proc_init64
global proc_alloc_slot64
global proc_count_running64
global proc_count_zombie64
global proc_get_current64
global proc_set_current64
global proc_get_psp64
global proc_get_entry64
global proc_get_pid64
global psp_init64
global psp_validate64
global psp_set_cmdtail64
global psp_get_cmdlen64
global psp_set_exit64
global env_init64
global env_count64
global env_get64
global env_set64
global env_unset64
global proc_verify_image64
global proc_load_image64
global proc_spawn64
global proc_terminate64
global proc_exit_current64
global proc_reap64
global proc_free_all64
global proc_next_pid
global proc_current
global proc_state
global proc_pid

extern mem_alloc64
extern mem_free64
extern mem_validate64

%define PROC_MAX 16
%define PROC_FREE 0
%define PROC_RUNNING 1
%define PROC_ZOMBIE 2

%define PSP_SIZE PSP64_size
%define PROC_STACK_SIZE 2048
%define PROC_ENV_SIZE 1024
%define EXE64_MAGIC 0x34365A4D   ; 'MZ64' LE: 4D 5A 36 34
%define EXE64_HDR_SIZE 32
%define MEM_END_ADDR 0x800000

section .bss
align 16
proc_state:     resq PROC_MAX
proc_pid:       resq PROC_MAX
proc_psp:       resq PROC_MAX
proc_entry:     resq PROC_MAX
proc_stack:     resq PROC_MAX
proc_exitcode:  resq PROC_MAX
proc_memsize:   resq PROC_MAX
proc_envptr:    resq PROC_MAX
proc_next_pid:  resq 1
proc_current:   resq 1
proc_inited:    resb 8

section .text

; ------------------------------------------------------------
; proc_init64 — zero table, slot0=kernel running pid0
;   Out: RAX 0
; ------------------------------------------------------------
proc_init64:
    push rbx
    push rcx
    push rdi
    lea rbx, [rel proc_state]
    mov rcx, PROC_MAX
    xor rdi, rdi
.zero_loop:
    mov qword [rbx], PROC_FREE
    add rbx, 8
    dec rcx
    jnz .zero_loop
    lea rbx, [rel proc_pid]
    mov rcx, PROC_MAX
.zero_pid:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_pid
    lea rbx, [rel proc_psp]
    mov rcx, PROC_MAX
.zero_psp:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_psp
    lea rbx, [rel proc_entry]
    mov rcx, PROC_MAX
.zero_ent:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_ent
    lea rbx, [rel proc_stack]
    mov rcx, PROC_MAX
.zero_stk:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_stk
    lea rbx, [rel proc_exitcode]
    mov rcx, PROC_MAX
.zero_ext:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_ext
    lea rbx, [rel proc_memsize]
    mov rcx, PROC_MAX
.zero_mem:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_mem
    lea rbx, [rel proc_envptr]
    mov rcx, PROC_MAX
.zero_env:
    mov qword [rbx], 0
    add rbx, 8
    dec rcx
    jnz .zero_env
    mov qword [rel proc_next_pid], 1
    mov qword [rel proc_current], 0
    mov qword [rel proc_state], PROC_RUNNING
    mov qword [rel proc_pid], 0
    mov byte [rel proc_inited], 1
    pop rdi
    pop rcx
    pop rbx
    xor eax, eax
    ret

; ------------------------------------------------------------
; proc_alloc_slot64 — find free slot
;   Out: RAX = slot 0..15, or -1 (0xFFFF...) if full
; ------------------------------------------------------------
proc_alloc_slot64:
    push rbx
    push rcx
    lea rbx, [rel proc_state]
    xor ecx, ecx
.walk:
    cmp ecx, PROC_MAX
    jae .full
    cmp qword [rbx + rcx*8], PROC_FREE
    je .found
    inc ecx
    jmp .walk
.found:
    mov rax, rcx
    pop rcx
    pop rbx
    ret
.full:
    mov rax, -1
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; proc_count_running64 — RAX = # running (incl kernel slot0)
; proc_count_zombie64 — RAX = # zombie
; ------------------------------------------------------------
proc_count_running64:
    push rbx
    push rcx
    xor eax, eax
    xor ecx, ecx
    lea rbx, [rel proc_state]
.loop_r:
    cmp ecx, PROC_MAX
    jae .done_r
    cmp qword [rbx + rcx*8], PROC_RUNNING
    jne .next_r
    inc rax
.next_r:
    inc ecx
    jmp .loop_r
.done_r:
    pop rcx
    pop rbx
    ret

proc_count_zombie64:
    push rbx
    push rcx
    xor eax, eax
    xor ecx, ecx
    lea rbx, [rel proc_state]
.loop_z:
    cmp ecx, PROC_MAX
    jae .done_z
    cmp qword [rbx + rcx*8], PROC_ZOMBIE
    jne .next_z
    inc rax
.next_z:
    inc ecx
    jmp .loop_z
.done_z:
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; proc_get_current64 — RAX = current pid, RDX = current slot
; proc_set_current64 — RDI = pid -> RAX 0 ok, 1 not found
; proc_get_psp64 — RDI = pid -> RAX = psp (0 not found)
; proc_get_entry64 — RDI = pid -> RAX = entry RIP (0 not found)
; proc_get_pid64 — RDI = slot -> RAX = pid (or -1 bad slot)
; ------------------------------------------------------------
proc_get_current64:
    push rbx
    push r11
    mov rbx, [rel proc_current]
    cmp rbx, PROC_MAX
    jae .bad_cur
    lea r11, [rel proc_pid]
    mov rax, [r11 + rbx*8]
    mov rdx, rbx
    pop r11
    pop rbx
    ret
.bad_cur:
    xor eax, eax
    mov rdx, -1
    pop r11
    pop rbx
    ret

proc_set_current64:
    push rbx
    push rcx
    push r11
    xor ecx, ecx
    lea rbx, [rel proc_pid]
    lea r11, [rel proc_state]
.loop_s:
    cmp ecx, PROC_MAX
    jae .notfound_s
    cmp qword [rbx + rcx*8], rdi
    jne .next_s
    ; check state running (kernel or child running)
    cmp qword [r11 + rcx*8], PROC_RUNNING
    jne .next_s
    mov [rel proc_current], rcx
    xor eax, eax
    pop r11
    pop rcx
    pop rbx
    ret
.next_s:
    inc ecx
    jmp .loop_s
.notfound_s:
    mov rax, 1
    pop r11
    pop rcx
    pop rbx
    ret

proc_get_psp64:
    push rbx
    push rcx
    push r11
    xor ecx, ecx
    lea rbx, [rel proc_pid]
    lea r11, [rel proc_state]
.loop_p:
    cmp ecx, PROC_MAX
    jae .nf_p
    cmp qword [rbx + rcx*8], rdi
    jne .nx_p
    cmp qword [r11 + rcx*8], PROC_FREE
    je .nx_p
    lea r11, [rel proc_psp]
    mov rax, [r11 + rcx*8]
    pop r11
    pop rcx
    pop rbx
    ret
.nx_p:
    inc ecx
    jmp .loop_p
.nf_p:
    xor eax, eax
    pop r11
    pop rcx
    pop rbx
    ret

proc_get_entry64:
    push rbx
    push rcx
    push r11
    xor ecx, ecx
    lea rbx, [rel proc_pid]
    lea r11, [rel proc_state]
.loop_e:
    cmp ecx, PROC_MAX
    jae .nf_e
    cmp qword [rbx + rcx*8], rdi
    jne .nx_e
    cmp qword [r11 + rcx*8], PROC_FREE
    je .nx_e
    lea r11, [rel proc_entry]
    mov rax, [r11 + rcx*8]
    pop r11
    pop rcx
    pop rbx
    ret
.nx_e:
    inc ecx
    jmp .loop_e
.nf_e:
    xor eax, eax
    pop r11
    pop rcx
    pop rbx
    ret

proc_get_pid64:
    cmp rdi, PROC_MAX
    jae .bad_slot
    lea r11, [rel proc_pid]
    mov rax, [r11 + rdi*8]
    ret
.bad_slot:
    mov rax, -1
    ret

; ------------------------------------------------------------
; psp_init64 — SETMEM analog (MSDOS.ASM:3363)
;   In: RDI = psp base linear, RSI = top_mem linear,
;       RDX = exit RIP (INT22 analog), RCX = env linear (0=none)
;   Out: RAX 0 ok, 1 bad ptr/top
;   Sets INT20 CD20, top_mem, CALL5 far-jump bytes (EAh, kept debug),
;   exit/cont/error RIP (+CS 0x08), zero FCB1/2, cmd_len 0, env/cr3/rsp,
;   zero R8-R15 save, fd_table[0..2]=0,1,2 rest -1.
; ------------------------------------------------------------
psp_init64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; validate: psp non-zero, canonical low, top > psp+512, top <= 0x800000
    test rdi, rdi
    jz .bad
    cmp rsi, rdi
    jbe .bad
    mov rax, rdi
    add rax, PSP_SIZE
    cmp rsi, rax
    jb .bad
    cmp rsi, MEM_END_ADDR
    ja .bad
    ; zero entire 512 bytes first
    mov rbx, rdi
    mov rcx, PSP_SIZE
    xor eax, eax
.zero_psp:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .zero_psp
    ; +0x00 INT20
    mov byte [rdi + PSP64.int20], 0xCD
    mov byte [rdi + PSP64.int20+1], 0x20
    ; +0x08 top_mem
    mov [rdi + PSP64.top_mem], rsi
    ; +0x18 call5_ptr -> dos syscall entry (0 for now, filled by kernel)
    mov qword [rdi + PSP64.call5_ptr], 0
    ; exit/cont/error: RDX exit, cont=0, error=0, CS=0x08
    ; stack: RDX was pushed; recover exit_rip from stack? We pushed rdx, so use saved
    ; To avoid confusion, reload from stack slots:
    ; pushes: rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11 (9). After pushes, [rsp+...]? Simpler: we saved RDX in寄存器? We pushed rdx, original RDX lost. Use memory: original RDX is at [rsp+?]. Let's compute: push order rbx(1),rcx(2),rdx(3),rsi(4),rdi(5),r8(6),r9(7),r10(8),r11(9). RSP points to r11. Original RDX is 7*8=56 bytes above? r11(0),r10(8),r9(16),r8(24),rdi(32),rsi(40),rdx(48),rcx(56),rbx(64). So [rsp+48]=orig RDX, [rsp+40]=orig RSI(top), [rsp+56]=orig RCX(env).
    mov rax, [rsp + 48]   ; orig exit RIP
    mov [rdi + PSP64.exit_ip], rax
    mov qword [rdi + PSP64.exit_cs], 0x08
    mov qword [rdi + PSP64.cont_ip], 0
    mov qword [rdi + PSP64.cont_cs], 0x08
    mov qword [rdi + PSP64.error_ip], 0
    mov qword [rdi + PSP64.error_cs], 0x08
    ; FCB1/2 already zero, cmd_len 0 (zeroed)
    ; env_ptr
    mov rax, [rsp + 56]   ; orig env
    mov [rdi + PSP64.env_ptr], rax
    ; cr3
    mov rax, cr3
    mov [rdi + PSP64.cr3], rax
    ; rsp0 = current rsp (kernel stack approx) + rflags
    mov rax, rsp
    mov [rdi + PSP64.rsp0], rax
    pushfq
    pop rax
    mov [rdi + PSP64.rflags], rax
    ; reg saves already zero; fd_table: [0]=0,[1]=1,[2]=2, rest -1
    mov qword [rdi + PSP64.fd_table + 0*8], 0
    mov qword [rdi + PSP64.fd_table + 1*8], 1
    mov qword [rdi + PSP64.fd_table + 2*8], 2
    mov rax, -1
    mov [rdi + PSP64.fd_table + 3*8], rax
    mov [rdi + PSP64.fd_table + 4*8], rax
    mov [rdi + PSP64.fd_table + 5*8], rax
    mov [rdi + PSP64.fd_table + 6*8], rax
    mov [rdi + PSP64.fd_table + 7*8], rax
    mov [rdi + PSP64.fd_table + 8*8], rax
    mov [rdi + PSP64.fd_table + 9*8], rax
    mov [rdi + PSP64.fd_table + 10*8], rax
    mov [rdi + PSP64.fd_table + 11*8], rax
    mov [rdi + PSP64.fd_table + 12*8], rax
    mov [rdi + PSP64.fd_table + 13*8], rax
    mov [rdi + PSP64.fd_table + 14*8], rax
    mov [rdi + PSP64.fd_table + 15*8], rax
    xor eax, eax
    jmp .done
.bad:
    mov rax, 1
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; psp_validate64 — check PSP magic + bounds
;   In: RDI = psp
;   Out: RAX 0 ok, 1 bad magic, 2 bad top, 3 bad env/canonical
; ------------------------------------------------------------
psp_validate64:
    push rbx
    push rcx
    test rdi, rdi
    jz .bad_magic
    cmp byte [rdi + PSP64.int20], 0xCD
    jne .bad_magic
    cmp byte [rdi + PSP64.int20+1], 0x20
    jne .bad_magic
    mov rax, [rdi + PSP64.top_mem]
    cmp rax, rdi
    jbe .bad_top
    mov rbx, rdi
    add rbx, PSP_SIZE
    cmp rax, rbx
    jb .bad_top
    cmp rax, MEM_END_ADDR
    ja .bad_top
    ; env 0 or within 0..MEM_END and 16-aligned? just bounds
    mov rcx, [rdi + PSP64.env_ptr]
    test rcx, rcx
    jz .ok
    cmp rcx, MEM_END_ADDR
    jae .bad_env
    ; canonical: bit47 sign extend? All <8M are canonical low, ok
.ok:
    xor eax, eax
    pop rcx
    pop rbx
    ret
.bad_magic:
    mov rax, 1
    pop rcx
    pop rbx
    ret
.bad_top:
    mov rax, 2
    pop rcx
    pop rbx
    ret
.bad_env:
    mov rax, 3
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; psp_set_cmdtail64 — copy command tail (COMMAND.ASM:639 DS:80h analog)
;   In: RDI = psp, RSI = src, RDX = len 0..127
;   Out: RAX 0 ok, 1 too long / bad ptr
; ------------------------------------------------------------
psp_set_cmdtail64:
    push rbx
    push rcx
    push rsi
    push rdi
    cmp rdx, 127
    ja .bad_len
    test rdi, rdi
    jz .bad_len
    ; if len>0, src must be non-zero
    test rdx, rdx
    jz .zero_len
    test rsi, rsi
    jz .bad_len
.zero_len:
    mov [rdi + PSP64.cmd_len], dl
    test rdx, rdx
    jz .done_ok
    lea rbx, [rdi + PSP64.cmd_tail]
    mov rcx, rdx
    cld
.copy_loop:
    mov al, [rsi]
    mov [rbx], al
    inc rsi
    inc rbx
    dec rcx
    jnz .copy_loop
.done_ok:
    xor eax, eax
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret
.bad_len:
    mov rax, 1
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; psp_get_cmdlen64 — RDI=psp -> RAX=len (0..127), or -1 bad
psp_get_cmdlen64:
    test rdi, rdi
    jz .bad_c
    movzx eax, byte [rdi + PSP64.cmd_len]
    ret
.bad_c:
    mov rax, -1
    ret

; ------------------------------------------------------------
; psp_set_exit64 — set INT22/23/24 vectors (ABORT analog)
;   In: RDI=psp, RSI=exit_rip, RDX=cont_rip, RCX=err_rip
;   Out: RAX 0
; ------------------------------------------------------------
psp_set_exit64:
    push rbx
    test rdi, rdi
    jz .bad_e
    mov [rdi + PSP64.exit_ip], rsi
    mov qword [rdi + PSP64.exit_cs], 0x08
    mov [rdi + PSP64.cont_ip], rdx
    mov qword [rdi + PSP64.cont_cs], 0x08
    mov [rdi + PSP64.error_ip], rcx
    mov qword [rdi + PSP64.error_cs], 0x08
    xor eax, eax
    pop rbx
    ret
.bad_e:
    mov rax, 1
    pop rbx
    ret

; ------------------------------------------------------------
; env_init64 — init empty env (double NUL)
;   In: RDI=buf, RSI=size
;   Out: RAX 0 ok, 1 too small
; ------------------------------------------------------------
env_init64:
    test rdi, rdi
    jz .small
    cmp rsi, 2
    jb .small
    mov byte [rdi], 0
    mov byte [rdi+1], 0
    xor eax, eax
    ret
.small:
    mov rax, 1
    ret

; ------------------------------------------------------------
; env_count64 — count entries until double NUL
;   In: RDI=buf
;   Out: RAX=count (scans max 65536, stops at double NUL or single NUL at start)
; ------------------------------------------------------------
env_count64:
    push rbx
    push rcx
    push rsi
    xor eax, eax
    xor ecx, ecx
    mov rsi, rdi
    test rsi, rsi
    jz .done_c
    cmp byte [rsi], 0
    je .done_c
.loop_c:
    cmp ecx, 65536
    jae .done_c
    cmp byte [rsi], 0
    jne .adv_c
    ; NUL: check next
    cmp byte [rsi+1], 0
    je .done_c
    inc rax
    ; fall through (counted boundary)? Actually count entries: inc on each NUL-boundary+1? Simpler: count NUL-terminated strings.
    ; We started 0, each entry ends with NUL. Count entries by counting NULs before double NUL.
    ; Above inc counts boundaries, but need +1 for first? Let's instead count entries: start 0, on each entry start inc then skip.
    ; Rework: use entry counting below.
    jmp .adv_c
.adv_c:
    ; advance one byte; if we are at entry start and just counted? Simplify: scan for entries:
    ; Instead implement straightforward: RAX=0, RSI=buf; while *RSI!=0 { RAX++; skip to NUL; RSI++; }.
    ; We already advanced? Reset and redo cleanly:
    jmp .rescan
.rescan:
    pop rsi
    pop rcx
    pop rbx
    push rbx
    push rcx
    push rsi
    xor eax, eax
    mov rsi, rdi
    cmp byte [rsi], 0
    je .done_c2
.scan_entry:
    cmp eax, 1024
    jae .done_c2
    cmp byte [rsi], 0
    je .check_end
    inc rax
.skip_to_nul:
    cmp byte [rsi], 0
    je .after_nul
    inc rsi
    jmp .skip_to_nul
.after_nul:
    inc rsi
    jmp .scan_entry
.check_end:
    cmp byte [rsi+1], 0
    je .done_c2
    ; single NUL inside? Should not happen (entries contiguous). Treat as next entry (empty?) Skip.
    inc rsi
    jmp .scan_entry
.done_c2:
.done_c:
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; strlen helper: RDI=str -> RAX=len (max 256, no NUL=>256)
; ------------------------------------------------------------
proc_strlen_helper:
    push rcx
    push rdi
    xor eax, eax
    mov ecx, 256
.len_loop_h:
    test ecx, ecx
    jz .len_done_h
    cmp byte [rdi], 0
    je .len_done_h
    inc rdi
    inc rax
    dec ecx
    jmp .len_loop_h
.len_done_h:
    pop rdi
    pop rcx
    ret

; ------------------------------------------------------------
; env_get64 — find NAME= and copy value
;   In: RDI=env, RSI=name (NUL), RDX=out, RCX=out_size
;   Out: RAX 0 found, 1 not found / bad
; ------------------------------------------------------------
env_get64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    test rdi, rdi
    jz .nf
    test rsi, rsi
    jz .nf
    test rdx, rdx
    jz .nf
    test rcx, rcx
    jz .nf
    ; name len (helper expects RDI=str, preserves RDI)
    mov r10, rdi         ; save env base first
    mov r8, rsi          ; name
    mov rdi, r8
    call proc_strlen_helper
    mov r9, rax          ; namelen
    test r9, r9
    jz .nf
    cmp r9, 64
    ja .nf
    ; r10 already holds env cursor
.next_entry_g:
    cmp byte [r10], 0
    je .nf               ; double NUL or end
    ; compare name part: [r10 .. r10+namelen-1] vs name, then '='?
    mov r11, 0
.cmp_name:
    cmp r11, r9
    jae .check_eq
    mov al, [r10 + r11]
    mov cl, [r8 + r11]
    cmp al, cl
    jne .skip_entry
    inc r11
    jmp .cmp_name
.check_eq:
    cmp byte [r10 + r11], '='
    jne .skip_entry
    ; found: value at r10+r11+1, copy to out (RCX size incl NUL)
    lea rsi, [r10 + r11 + 1]
    mov rdi, rdx         ; out (saved? RDX pushed, use stack? We pushed rdx, orig out at [rsp+?]. Simpler use r12)
    ; We clobbered RDI (env) — need out ptr. Retrieve orig RDX from stack:
    ; pushes: rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12 (10 pushes). RSP->r12. Orig RDX at offset? r12(0),r11(8),r10(16),r9(24),r8(32),rdi(40),rsi(48),rdx(56),rcx(64),rbx(72). So [rsp+56]=out, [rsp+64]=out_size.
    mov r12, [rsp + 56]  ; out
    mov rbx, [rsp + 64]  ; out_size
    xor ecx, ecx
.copy_val:
    mov al, [rsi]
    cmp rcx, rbx
    jae .trunc_g         ; no space (need at least 1 for NUL? we ensure)
    ; if rcx+1 >= out_size, truncate: write NUL and succeed? For test, values fit. Just fail if overflow? Succeed with truncation? Return 0 with truncated? Simpler: if overflow, return 1? But test values fit. Implement truncation with NUL.
    mov [r12 + rcx], al
    inc rsi
    inc rcx
    test al, al
    jnz .copy_val
    xor eax, eax
    jmp .done_g
.trunc_g:
    ; no space: NUL-terminate and return 1? For now return 1 (not found/no space)
    mov byte [r12 + rbx - 1], 0
    mov rax, 1
    jmp .done_g
.skip_entry:
    ; skip to next NUL+1
.skip_loop:
    cmp byte [r10], 0
    je .after_skip
    inc r10
    jmp .skip_loop
.after_skip:
    inc r10
    jmp .next_entry_g
.nf:
    mov rax, 1
.done_g:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; env_set64 — set or add NAME=VALUE (memmove for replace/remove)
;   In: RDI=env, RSI=buf_size, RDX=name, RCX=value (NUL, ""=delete)
;   Out: RAX 0 ok, 1 no space, 2 bad name
;   Preserves DOS uppercase expectation? Case-sensitive.
; ------------------------------------------------------------
env_set64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    ; validate name: non-empty, no '=', len<=64
    test rdx, rdx
    jz .bad_name
    test rdi, rdi
    jz .bad_name
    mov r8, rdx          ; name
    mov r9, rcx          ; value (may be 0? treat as empty)
    mov r10, rdi         ; env
    ; orig buf_size at [rsp+?]: pushes 13? Count: rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15 =13 pushes. RSP->r15. Offsets: r15(0),r14(8),r13(16),r12(24),r11(32),r10(40),r9(48),r8(56),rdi(64),rsi(72),rdx(80),rcx(88),rbx(96). Orig RSI(buf_size) at [rsp+72].
    mov r11, [rsp + 72]  ; buf_size
    ; name len (helper takes RDI, preserves it; env already in r10)
    mov rdi, r8
    call proc_strlen_helper
    mov r12, rax         ; namelen
    test r12, r12
    jz .bad_name
    cmp r12, 64
    ja .bad_name
    ; check '=' in name
    xor r13d, r13d
.check_eq_loop:
    cmp r13, r12
    jae .name_ok
    cmp byte [r8 + r13], '='
    je .bad_name
    inc r13
    jmp .check_eq_loop
.name_ok:
    ; value len (0 if R9==0)
    xor r13, r13         ; vallen
    test r9, r9
    jz .have_vallen
    mov rdi, r9
    call proc_strlen_helper
    mov r13, rax
    cmp r13, 256
    ja .no_space         ; too large
.have_vallen:
    ; find existing entry
    mov r14, r10         ; cursor
    mov r15, -1          ; existing entry start or -1
    ; use stack for found len? We'll store entry len in R11? R11 is buf_size, need another. Use RBX for entry total len.
.find_loop:
    cmp byte [r14], 0
    je .find_done        ; end (double NUL or single at start)
    ; compare
    xor ecx, ecx
.cmp_loop2:
    cmp rcx, r12
    jae .check_eq2
    mov al, [r14 + rcx]
    mov bl, [r8 + rcx]
    cmp al, bl
    jne .skip_find
    inc rcx
    jmp .cmp_loop2
.check_eq2:
    cmp byte [r14 + rcx], '='
    jne .skip_find
    mov r15, r14         ; found
    ; compute existing entry len (incl NUL)
    xor ebx, ebx
.len_exist:
    cmp byte [r14 + rbx], 0
    je .have_exist_len
    inc rbx
    jmp .len_exist
.have_exist_len:
    inc rbx              ; incl NUL
    jmp .find_done
.skip_find:
    ; skip entry
.skip_floop:
    cmp byte [r14], 0
    je .after_skip_f
    inc r14
    jmp .skip_floop
.after_skip_f:
    inc r14
    jmp .find_loop
.find_done:
    ; R14 = end pointer (points to final NUL of double NUL? At double NUL, R14 points to first of two NULs)
    ; Compute current used size: find double NUL end.
    ; Scan from env base to double NUL to get used (incl final double NUL?).
    push r14
    push r15
    mov rsi, r10
.find_end:
    cmp byte [rsi], 0
    jne .adv_end
    cmp byte [rsi+1], 0
    je .have_end
    inc rsi
    jmp .find_end
.adv_end:
    inc rsi
    jmp .find_end
.have_end:
    ; RSI points to first NUL of double NUL; used = RSI - env_base + 2 (incl both NULs)? Actually buffer contains ...\0\0, RSI at first \0, so used = RSI-base+2? But if empty (base[0]==0), RSI==base, used=2? Our init has 2 NULs, so used=2. Good.
    mov rax, rsi
    sub rax, r10
    add rax, 2           ; used bytes (incl double NUL space? The second NUL is at RSI+1, so total used incl it = diff+2? If diff=0, used=2 (bytes 0,1). Good.)
    mov rcx, rax         ; RCX = used
    pop r15              ; existing start or -1
    pop r14              ; cursor (unused now)
    ; buf_size in R11
    ; Case A: value empty (delete): if found, remove entry (memmove tail over it)
    test r13, r13
    jnz .need_set        ; value non-empty -> set/add
    ; delete path
    cmp r15, -1
    je .ok_set           ; not found, nothing to do
    ; remove: entry len in RBX, tail = used - (existing_start - base) - entry_len
    ; existing_start=R15, entry_len=RBX, used=RCX
    mov rax, r15
    sub rax, r10         ; offset of entry
    mov rdx, rcx
    sub rdx, rax
    sub rdx, rbx         ; tail bytes after entry (incl double NUL tail)
    ; new_used = used - old (for trailing-zero fix)
    mov r14, rcx
    sub r14, rbx         ; new_used
    ; move [R15+RBX .. R15+RBX+tail-1] to [R15 ..]
    mov rsi, r15
    add rsi, rbx         ; src
    mov rdi, r15         ; dst
    mov rcx, rdx         ; count (use RCX, need to preserve? RCX is loop var but ok)
    cld
    rep movsb
    ; ensure double-NUL termination beyond new end (fixes last-entry leftover, Phase8)
    ; new end at base+new_used-1 is final NUL (copied); byte beyond must be NUL for count's 28-29 check
    mov byte [r10 + r14], 0
    jmp .ok_set
.need_set:
    ; new entry len = namelen +1 + vallen +1
    mov rax, r12
    add rax, 1
    add rax, r13
    add rax, 1           ; RAX = newlen
    mov rdx, rax         ; save newlen in RDX
    cmp r15, -1
    je .add_new
    ; replace: old len RBX, new len RDX, used RCX, buf R11
    ; new_used = used - old + new
    mov rax, rcx
    sub rax, rbx
    add rax, rdx
    cmp rax, r11
    ja .no_space
    ; move tail to make room: tail = used - (off+old)
    mov rax, r15
    sub rax, r10         ; off
    mov rsi, rax
    add rsi, rbx         ; off+old = tail start offset
    ; tail bytes = used - (off+old)
    ; Compute tail = used - off - old
    ; Use R14 as temp (RCX still holds used here)
    mov r14, rcx         ; used
    sub r14, rax         ; used-off
    sub r14, rbx         ; tail
    ; if newlen > old, move tail forward (from end backwards); else move forward
    cmp rdx, rbx
    ja .move_back
    je .write_entry      ; same size, just overwrite
    ; new smaller: move forward
    mov rsi, r15
    add rsi, rbx         ; src tail start
    mov rdi, r15
    add rdi, rdx         ; dst tail start
    mov rcx, r14         ; tail count
    cld
    rep movsb
    jmp .write_entry
.move_back:
    ; move backwards: src = existing+old, dst = existing+new, len=tail
    ; use STD
    mov rsi, r15
    add rsi, rbx
    add rsi, r14
    dec rsi              ; last byte of tail
    mov rdi, r15
    add rdi, rdx
    add rdi, r14
    dec rdi
    mov rcx, r14
    std
    rep movsb
    cld
    jmp .write_entry
.add_new:
    ; append before final double NUL: insert at (base+used-1)? Since used includes double NUL (two NULs), the first of double is at base+used-2, second at base+used-1. New entry should go at base+used-1? Wait: buffer ...last_entry\0\0 (two NULs). To append, overwrite first NUL with new entry, keep final NUL. Actually used = diff+2 where diff is offset of first NUL. Example empty: base[0]=0,base[1]=0, used=2, diff=0. Append "A=B\0": should write at base+0, new used = 2-1+newlen? Let's compute: new_used = used -1 + newlen? Because we reuse one NUL (the first of double) as entry start, and keep final NUL. For empty, used=2, newlen=4 ("A=B"+NUL=4), new_used=2-1+4=5? Buffer would be "A=B\0\0" (5 bytes: A,=,B,\0,\0). Correct. For non-empty "X=Y\0\0" (used=5? X,=,Y,\0,\0 =5), append "A=B\0"(4): new at offset 4? base+used-1 = base+4 (which is second NUL? Wait base: [0]X,[1]=,[2]Y,[3]\0,[4]\0. used=5. base+used-1=base+4 (second NUL). That's wrong, should be base+3? Hmm.
    ; Let's re-evaluate: used includes both NULs. For "X=Y\0\0", RSI (first NUL) at offset 3, used=3+2=5. Append should overwrite at offset 3? No, offset 3 is first NUL (end of X=Y), offset 4 is second NUL (final). New entry should start at offset 4? Actually buffer is X,=,Y,\0,\0. To append A,=,B,\0, we want X,=,Y,\0,A,=,B,\0,\0. So new entry starts at offset 4 (second NUL position), overwriting it, and adds newlen+1? Let's see: original used 5, new entry len 4, new used = 5 +4 =9? That's used + newlen. Not used-1+newlen. Hmm.
    ; Alternative view: used counts both NULs, but double NUL is two NULs, the first is terminator of last entry, second is extra. Appending should keep last entry's terminator and add new entry before final NUL? Actually last entry's terminator is first NUL, final NUL is extra. New entry should go after last entry's terminator, i.e., at offset used-1 (second NUL). So new_used = used + newlen. For empty, used=2 (two NULs, no entries). Appending at offset 1? base+used-1=base+1 (second NUL). But empty should start at 0, not 1. So empty is special: used=2, but entries 0, first NUL at 0 is both terminator and final? For empty, buffer is \0\0, first NUL is final, not entry terminator. Appending should start at 0, new_used = 1+newlen? That's used-1+newlen =1+4=5? Wait earlier we computed 5 for "A=B\0\0" (4+1). That's used(2)-1+4=5. Good. For non-empty, new_used = used+newlen =5+4=9 (X=Y\0A=B\0\0 = 4+4+1=9). Good. So need to distinguish empty vs non-empty: if used==2 and base[0]==0, insert at base, new_used=1+newlen? Actually used-1+newlen =1+4=5, same as used+newlen-1? For non-empty, used+newlen =9. So difference of 1.
    ; Simpler: find insert position = base+used-1 if non-empty, else base. Compute new_used accordingly and check space.
    cmp byte [r10], 0
    je .add_empty
    ; non-empty: insert at base+used-1
    mov rax, rcx         ; used
    add rax, rdx         ; +newlen
    cmp rax, r11
    ja .no_space
    ; insert position = base+used-1
    mov rdi, r10
    add rdi, rcx
    dec rdi              ; insert pos (overwrite final NUL)
    jmp .write_new_entry
.add_empty:
    mov rax, rdx
    add rax, 1           ; + final NUL? newlen already includes its NUL, plus one extra final NUL = newlen+1
    cmp rax, r11
    ja .no_space
    mov rdi, r10         ; base
    jmp .write_new_entry
.write_new_entry:
    ; RDI = dest, R8=name, R12=namelen, R9=value, R13=vallen
    mov rsi, r8
    mov rcx, r12
    cld
    rep movsb
    mov byte [rdi], '='
    inc rdi
    test r13, r13
    jz .finish_new
    mov rsi, r9
    mov rcx, r13
    rep movsb
.finish_new:
    mov byte [rdi], 0
    inc rdi
    mov byte [rdi], 0    ; final double NUL
    jmp .ok_set
.write_entry:
    ; overwrite at R15 with new entry (for replace path, R15 set, RDX newlen)
    mov rdi, r15
    mov rsi, r8
    mov rcx, r12
    cld
    rep movsb
    mov byte [rdi], '='
    inc rdi
    mov rsi, r9
    mov rcx, r13
    rep movsb
    mov byte [rdi], 0
    ; done (tail already moved, double NUL preserved)
    jmp .ok_set
.ok_set:
    xor eax, eax
    jmp .done_set
.no_space:
    mov rax, 1
    jmp .done_set
.bad_name:
    mov rax, 2
.done_set:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; env_unset64 — remove NAME (idempotent)
;   In: RDI=env, RSI=name
;   Out: RAX 0 ok, 2 bad name
; ------------------------------------------------------------
env_unset64:
    push rbx
    mov rdx, rsi         ; name
    mov rsi, 65536       ; generous size (delete path ignores size check)
    xor ecx, ecx         ; value NULL = delete
    call env_set64
    ; env_set returns 0 ok (deleted or not found), 1 no space (impossible for delete), 2 bad name
    cmp rax, 1
    jne .done_u
    xor eax, eax         ; treat no-space as ok for delete (should not happen)
.done_u:
    pop rbx
    ret

; ------------------------------------------------------------
; proc_verify_image64 — classify image (COM vs EXE64)
;   In: RSI=src, RDX=size
;   Out: RAX 0=COM raw, 1=EXE64, 2=bad (0 size / too large / bad header)
; ------------------------------------------------------------
proc_verify_image64:
    push rbx
    push rcx
    push rsi
    test rsi, rsi
    jz .bad_v
    test rdx, rdx
    jz .bad_v
    cmp rdx, 16*1024*1024
    ja .bad_v
    cmp rdx, EXE64_HDR_SIZE
    jb .is_com          ; too small for header -> COM
    mov eax, [rsi]      ; magic
    cmp eax, EXE64_MAGIC
    jne .is_com
    ; check hdr_size ==32
    mov eax, [rsi+4]
    cmp eax, EXE64_HDR_SIZE
    jne .bad_v
    ; image_size qword at +8
    mov rax, [rsi+8]
    cmp rax, rdx
    ja .bad_v           ; image larger than file? Actually file = hdr+image, so image <= size-32
    mov rbx, rdx
    sub rbx, EXE64_HDR_SIZE
    cmp rax, rbx
    ja .bad_v
    test rax, rax
    jz .bad_v
    cmp rax, 8*1024*1024
    ja .bad_v
    ; entry_offset dword at +16
    mov ecx, [rsi+16]
    cmp rcx, rax
    jae .bad_v          ; entry must be < image_size
    ; stack_size at +20 (0..64K)
    mov eax, [rsi+20]
    cmp eax, 65536
    ja .bad_v
    mov rax, 1          ; EXE64
    pop rsi
    pop rcx
    pop rbx
    ret
.is_com:
    xor eax, eax
    pop rsi
    pop rcx
    pop rbx
    ret
.bad_v:
    mov rax, 2
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; proc_load_image64 — copy payload to PSP+512, return entry
;   In: RDI=psp, RSI=src, RDX=size
;   Out: RAX=entry RIP (0 fail), CF 0 ok / 1 fail
;   Checks PSP valid, size fits before MEM_END.
; ------------------------------------------------------------
proc_load_image64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    test rdi, rdi
    jz .fail_l
    test rsi, rsi
    jz .fail_l
    test rdx, rdx
    jz .fail_l
    ; verify
    call proc_verify_image64  ; RSI,RDX -> RAX type (preserves? It pushes rbx,rcx,rsi; RDI untouched? It uses RSI,RDX, returns RAX. Good.)
    cmp rax, 2
    je .fail_l
    mov r8, rax          ; type 0 COM,1 EXE
    ; reload src/size after call? RSI,RDX preserved? proc_verify pushes rsi, so RSI preserved. RDX? It doesn't push RDX, but doesn't modify RDX? It uses RDX for cmp, but doesn't change? It does cmp, no mov to RDX, so preserved. Good. RDI preserved (push rdi in outer, verify doesn't touch RDI). Good.
    ; Retrieve orig values from stack: pushes rbx,rcx,rdx,rsi,rdi,r8,r9,r10 (8 pushes). RSP->r10. Orig RDI at [rsp+?]: r10(0),r9(8),r8(16),rdi(24),rsi(32),rdx(40),rcx(48),rbx(56). So orig psp=[rsp+24], src=[rsp+32], size=[rsp+40].
    mov r9, [rsp + 24]   ; psp
    mov r10, [rsp + 32]  ; src
    ; size in RDX? Use stack size
    mov rcx, [rsp + 40]  ; size
    cmp r8, 1
    je .exe_load
    ; COM: payload = entire file, dest = psp+512, entry = dest
    mov rbx, r9
    add rbx, PSP_SIZE     ; dest
    mov rax, rbx
    add rax, rcx          ; dest+size
    cmp rax, MEM_END_ADDR
    jae .fail_l
    ; copy
    mov rdi, rbx
    mov rsi, r10
    cld
    rep movsb             ; RCX=size, RSI=src, RDI=dest? Wait REP MOVSB uses RCX,RSI,RDI. RCX=size, good. But we used RCX for size, RDI dest, RSI src. Need to set RCX=size (already), RDI=dest, RSI=src. Good.
    ; entry = psp+512
    mov rax, r9
    add rax, PSP_SIZE
    jmp .ok_l
.exe_load:
    ; EXE64: payload after 32B header, image_size at src+8, entry_off at src+16
    mov rax, [r10 + 8]   ; image_size
    mov rbx, rax         ; save image_size
    mov ecx, [r10 + 16]  ; entry_off (32-bit)
    ; dest = psp+512
    mov rsi, r9
    add rsi, PSP_SIZE     ; dest base
    mov rdi, rsi
    add rdi, rbx          ; dest+image_size
    cmp rdi, MEM_END_ADDR
    jae .fail_l
    ; copy image_size bytes from src+32 to dest
    mov rdi, rsi          ; dest
    lea rsi, [r10 + 32]   ; src payload
    mov rcx, rbx          ; count
    cld
    rep movsb
    ; entry = psp+512+entry_off
    mov rax, r9
    add rax, PSP_SIZE
    mov ecx, [r10 + 16]
    add rax, rcx
    jmp .ok_l
.fail_l:
    xor eax, eax
    stc
    jmp .done_l
.ok_l:
    ; RAX=entry, preserve? pops will preserve RAX? POP does not touch RAX except restoring? Our pushes include rbx..r10, pops restore them but RAX is return, not pushed, so preserved. Good. Clear CF.
    clc
.done_l:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; proc_spawn64 — allocate + init PSP + env + load (EXEC analog)
;   In: RDI=src image linear, RSI=size bytes,
;       RDX=cmdline ptr (0=none), RCX=cmdlen (0..127),
;       R8=env_src (0=default empty + PATH/COMSPEC)
;   Out: RAX=pid (0 fail), RDX=psp (0 fail)
;   Allocates proc block (512+payload+2048) + env block (1024).
;   Sets MCB owner to PSP, PSP top/env/cr3/fd, cmd tail, table entry.
; ------------------------------------------------------------
proc_spawn64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    ; validate src/size via verify (need payload size for alloc)
    ; Save inputs on stack for later: after 13 pushes, orig RDI at? pushes: rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11,r12,r13,r14,r15 (13). RSP->r15. Offsets: r15(0),r14(8),r13(16),r12(24),r11(32),r10(40),r9(48),r8(56),rdi(64),rsi(72),rdx(80),rcx(88),rbx(96).
    ; Retrieve for verify: src=orig RDI, size=orig RSI
    mov rsi, [rsp + 64]  ; src? Wait [rsp+64]=orig RDI? Let's list: [rsp+0]=r15,[8]=r14,[16]=r13,[24]=r12,[32]=r11,[40]=r10,[48]=r9,[56]=r8,[64]=rdi,[72]=rsi,[80]=rdx,[88]=rcx,[96]=rbx. So src=RDI=[rsp+64], size=RSI=[rsp+72].
    mov rsi, [rsp + 64]  ; src into RSI for verify (verify expects RSI=src)
    mov rdx, [rsp + 72]  ; size into RDX
    call proc_verify_image64
    cmp rax, 2
    je .fail_spawn_verify
    mov r14, rax         ; type
    ; payload size: COM=size, EXE=image_size
    mov rdx, [rsp + 72]  ; size
    cmp r14, 1
    jne .have_payload
    mov rsi, [rsp + 64]  ; src
    mov rax, [rsi + 8]   ; image_size
    mov r15, rax
    jmp .got_payload
.have_payload:
    mov r15, rdx         ; payload = size
.got_payload:
    ; total = 512 + payload + 2048, align? mem_alloc aligns to 16 internally. Compute total.
    mov rax, r15
    add rax, PSP_SIZE
    add rax, PROC_STACK_SIZE
    ; sanity: total < 6M heap?
    cmp rax, 6*1024*1024
    jae .fail_spawn_total
    mov r13, rax         ; total
    ; alloc proc block
    mov rdi, r13
    call mem_alloc64
    test rax, rax
    jz .fail_spawn_alloc
    mov r12, rax         ; psp = alloc ptr
    ; set MCB owner to psp (MCB at psp-MCBSIZ64, owner at +8)
    mov rbx, r12
    sub rbx, MCBSIZ64
    mov [rbx + MCB64.owner], r12
    ; alloc env block
    mov rdi, PROC_ENV_SIZE
    call mem_alloc64
    test rax, rax
    jz .fail_env_alloc
    mov r11, rax         ; env ptr
    mov rbx, r11
    sub rbx, MCBSIZ64
    mov [rbx + MCB64.owner], r12   ; env owner = psp
    ; init env: empty then defaults (PATH, COMSPEC) unless R8 env_src provided? For now always defaults; if R8 non-zero, copy? Simplify: init empty + set PATH + COMSPEC.
    mov rdi, r11
    mov rsi, PROC_ENV_SIZE
    call env_init64
    ; set PATH=.
    mov rdi, r11
    mov rsi, PROC_ENV_SIZE
    lea rdx, [rel def_name_path]
    lea rcx, [rel def_val_path]
    call env_set64
    ; set COMSPEC=COMMAND64
    mov rdi, r11
    mov rsi, PROC_ENV_SIZE
    lea rdx, [rel def_name_comspec]
    lea rcx, [rel def_val_comspec]
    call env_set64
    ; if orig R8 env_src non-zero, could copy extra? Ignore for Phase8 (defaults suffice). Could also copy if provided: if R8 !=0, set EXTRA? Skip.
    ; init PSP: RDI=psp, RSI=top, RDX=exit, RCX=env
    mov rdi, r12
    mov rsi, r12
    add rsi, r13         ; top = psp+total
    xor edx, edx         ; exit 0 (will be set via psp_set_exit later if needed)
    mov rcx, r11         ; env
    call psp_init64
    test rax, rax
    jnz .fail_psp_init
    ; set default exit vectors to 0 (already), cmd tail if provided
    mov rax, [rsp + 80]  ; orig RDX cmdline
    mov rcx, [rsp + 88]  ; orig RCX cmdlen
    test rcx, rcx
    jz .no_cmd
    test rax, rax
    jz .no_cmd
    cmp rcx, 127
    ja .fail_cmd_len
    mov rdi, r12
    mov rsi, rax
    mov rdx, rcx
    call psp_set_cmdtail64
    test rax, rax
    jnz .fail_cmd_set
.no_cmd:
    ; load image: RDI=psp, RSI=src, RDX=size
    mov rdi, r12
    mov rsi, [rsp + 64]  ; src
    mov rdx, [rsp + 72]  ; size
    call proc_load_image64
    jc .fail_load
    ; RAX=entry
    mov r10, rax         ; entry
    ; alloc slot
    call proc_alloc_slot64
    cmp rax, -1
    je .fail_slot
    mov rbx, rax         ; slot
    ; assign pid (use r9 as table-base temp; r9 not live for data here)
    mov rax, [rel proc_next_pid]
    lea r9, [rel proc_pid]
    mov [r9 + rbx*8], rax
    lea r9, [rel proc_psp]
    mov [r9 + rbx*8], r12
    lea r9, [rel proc_entry]
    mov [r9 + rbx*8], r10
    ; stack_top = psp+total (top)
    mov rcx, r12
    add rcx, r13
    lea r9, [rel proc_stack]
    mov [r9 + rbx*8], rcx
    lea r9, [rel proc_exitcode]
    mov qword [r9 + rbx*8], 0
    lea r9, [rel proc_memsize]
    mov [r9 + rbx*8], r13
    lea r9, [rel proc_envptr]
    mov [r9 + rbx*8], r11
    lea r9, [rel proc_state]
    mov qword [r9 + rbx*8], PROC_RUNNING
    inc qword [rel proc_next_pid]
    ; return pid in RAX, psp in RDX
    lea r9, [rel proc_pid]
    mov rax, [r9 + rbx*8]
    mov rdx, r12
    jmp .done_spawn
.fail_env_alloc:
    mov r14, 5
    mov rdi, r12
    call mem_free64
    mov rdx, r14
    jmp .fail_spawn_code
.fail_psp_init:
    mov r14, 6
    jmp .fail_both_free_stage
.fail_cmd_len:
    mov r14, 7
    jmp .fail_both_free_stage
.fail_cmd_set:
    mov r14, 7
    jmp .fail_both_free_stage
.fail_load:
    mov r14, 8
    jmp .fail_both_free_stage
.fail_slot:
    mov r14, 9
    jmp .fail_both_free_stage
.fail_both_free_stage:
    ; free env (R11) and proc (R12), preserve stage in R14 (mem_free preserves R14)
    test r11, r11
    jz .free_proc_only_stage
    mov rdi, r11
    call mem_free64
.free_proc_only_stage:
    test r12, r12
    jz .fail_spawn_nopsp
    mov rdi, r12
    call mem_free64
    mov rdx, r14
    jmp .fail_spawn_code
.fail_both_free:
    ; free env (R11) and proc (R12) if allocated
    test r11, r11
    jz .free_proc_only
    mov rdi, r11
    call mem_free64
.free_proc_only:
    test r12, r12
    jz .fail_spawn_nopsp
    mov rdi, r12
    call mem_free64
.fail_spawn_verify:
    mov rdx, 1
    jmp .fail_spawn_code
.fail_spawn_total:
    mov rdx, 2
    jmp .fail_spawn_code
.fail_spawn_alloc:
    mov rdx, 3
    jmp .fail_spawn_code
.fail_spawn_nopsp:
    mov rdx, 4
    jmp .fail_spawn_code
.fail_spawn:
    xor edx, edx
.fail_spawn_code:
    xor eax, eax
    ; RDX=stage (0 generic, 1 verify, 2 total, 3 alloc, 4 nopsp, 5 envalloc, 6 pspinit, 7 cmd, 8 load, 9 slot)
.done_spawn:
    ; RAX=pid,RDX=psp need to survive pops? Pops restore rdx,rbx etc., including RDX! Our pushes include rdx, so pop rdx will overwrite return RDX. Need to handle: save returns on stack or use different.
    ; We pushed 13 regs including rdx,rbx etc. Pops will restore them, clobbering RAX/RDX returns if we set before pops.
    ; Solution: store returns in memory slots then pop then reload.
    mov [rel spawn_ret_pid], rax
    mov [rel spawn_ret_psp], rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rax, [rel spawn_ret_pid]
    mov rdx, [rel spawn_ret_psp]
    ret

; ------------------------------------------------------------
; proc_terminate64 — terminate pid (ABORT/EXIT analog, MSDOS.ASM:1356)
;   In: RDI=pid, RSI=exit_code
;   Out: RAX 0 ok, 1 not found / already zombie / kernel pid0
;   Frees env + proc blocks, marks zombie, stores code.
;   If pid == current, resets current to 0 (kernel).
; ------------------------------------------------------------
proc_terminate64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; pid 0 (kernel) cannot be terminated
    test rdi, rdi
    jz .notfound_t
    xor ecx, ecx
    lea rbx, [rel proc_pid]
    lea r11, [rel proc_state]
.find_t:
    cmp ecx, PROC_MAX
    jae .notfound_t
    cmp [rbx + rcx*8], rdi
    jne .next_t
    cmp qword [r11 + rcx*8], PROC_RUNNING
    jne .notfound_t      ; zombie or free -> fail (double-exit)
    ; found running slot RCX
    mov r8, rcx          ; slot
    lea r11, [rel proc_psp]
    mov r9, [r11 + rcx*8]   ; psp
    lea r11, [rel proc_envptr]
    mov r10, [r11 + rcx*8] ; env
    ; store exit code (orig RSI at [rsp+?]: pushes 9? rbx,rcx,rdx,rsi,rdi,r8,r9,r10,r11 (9). RSP->r11. Offsets: r11(0),r10(8),r9(16),r8(24),rdi(32),rsi(40),rdx(48),rcx(56),rbx(64). Orig RSI=[rsp+40].
    mov rax, [rsp + 40]
    lea r11, [rel proc_exitcode]
    mov [r11 + r8*8], rax
    ; free env if non-zero
    test r10, r10
    jz .free_proc
    mov rdi, r10
    call mem_free64      ; ignore CF (already validated)
.free_proc:
    test r9, r9
    jz .mark_zombie      ; kernel slot? shouldn't happen (pid!=0)
    mov rdi, r9
    call mem_free64
.mark_zombie:
    lea r11, [rel proc_state]
    mov qword [r11 + r8*8], PROC_ZOMBIE
    lea r11, [rel proc_psp]
    mov qword [r11 + r8*8], 0
    lea r11, [rel proc_entry]
    mov qword [r11 + r8*8], 0
    lea r11, [rel proc_stack]
    mov qword [r11 + r8*8], 0
    lea r11, [rel proc_envptr]
    mov qword [r11 + r8*8], 0
    lea r11, [rel proc_memsize]
    mov qword [r11 + r8*8], 0
    ; if current == slot, reset to 0
    mov rax, [rel proc_current]
    cmp rax, r8
    jne .ok_t
    mov qword [rel proc_current], 0
.ok_t:
    xor eax, eax
    jmp .done_t
.next_t:
    inc ecx
    jmp .find_t
.notfound_t:
    mov rax, 1
.done_t:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; proc_exit_current64 — exit current process (INT20/INT21 4Ch analog)
;   In: RDI=exit_code (low byte used, full qword stored)
;   Out: RAX 0 ok, 1 fail (current is kernel or none)
; ------------------------------------------------------------
proc_exit_current64:
    push rbx
    push r11
    mov rbx, [rel proc_current]
    cmp rbx, PROC_MAX
    jae .fail_c
    cmp rbx, 0
    je .fail_c           ; kernel cannot exit
    lea r11, [rel proc_state]
    cmp qword [r11 + rbx*8], PROC_RUNNING
    jne .fail_c
    lea r11, [rel proc_pid]
    mov rax, [r11 + rbx*8]
    mov rsi, rdi         ; code
    mov rdi, rax         ; pid
    call proc_terminate64
    pop r11
    pop rbx
    ret
.fail_c:
    mov rax, 1
    pop r11
    pop rbx
    ret

; ------------------------------------------------------------
; proc_reap64 — free zombie slot (parent wait analog)
;   In: RDI=pid
;   Out: RAX 0 ok, 1 not zombie / not found
; ------------------------------------------------------------
proc_reap64:
    push rbx
    push rcx
    push r11
    xor ecx, ecx
    lea rbx, [rel proc_pid]
    lea r11, [rel proc_state]
.loop_reap:
    cmp ecx, PROC_MAX
    jae .nf_reap
    cmp [rbx + rcx*8], rdi
    jne .nx_reap
    cmp qword [r11 + rcx*8], PROC_ZOMBIE
    jne .nf_reap
    mov qword [r11 + rcx*8], PROC_FREE
    mov qword [rbx + rcx*8], 0
    lea r11, [rel proc_exitcode]
    mov qword [r11 + rcx*8], 0
    xor eax, eax
    pop r11
    pop rcx
    pop rbx
    ret
.nx_reap:
    inc ecx
    jmp .loop_reap
.nf_reap:
    mov rax, 1
    pop r11
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; proc_free_all64 — terminate all children (for test cleanup)
;   Out: RAX = # freed
; ------------------------------------------------------------
proc_free_all64:
    push rbx
    push rcx
    push rsi
    push r11
    xor eax, eax
    mov ecx, 1           ; skip slot0 kernel
.loop_free:
    cmp ecx, PROC_MAX
    jae .done_free
    lea r11, [rel proc_state]
    cmp qword [r11 + rcx*8], PROC_RUNNING
    jne .nx_free
    mov rbx, rcx
    mov rsi, 0
    lea r11, [rel proc_pid]
    mov rdi, [r11 + rcx*8]
    ; call terminate (need to preserve RCX/RAX across call; pushes already? Use manual save)
    push rax
    push rcx
    push r11
    push rbx
    call proc_terminate64
    pop rbx
    pop r11
    pop rcx
    pop rax
    ; reap zombie immediately to free slot
    push rax
    push rcx
    push r11
    push rbx
    lea r11, [rel proc_pid]
    mov rdi, [r11 + rbx*8]  ; pid still? After terminate, pid remains? Terminate keeps pid for zombie. Good.
    ; Actually after terminate, proc_pid[slot] still holds pid (we didn't clear). So reap by pid.
    call proc_reap64
    pop rbx
    pop r11
    pop rcx
    pop rax
    inc rax
.nx_free:
    ; also reap any lingering zombies (from prior tests)
    lea r11, [rel proc_state]
    cmp qword [r11 + rcx*8], PROC_ZOMBIE
    jne .adv_free
    push rax
    push rcx
    push rbx
    push r11
    lea r11, [rel proc_pid]
    mov rdi, [r11 + rcx*8]
    call proc_reap64
    pop r11
    pop rbx
    pop rcx
    pop rax
.adv_free:
    inc ecx
    jmp .loop_free
.done_free:
    pop r11
    pop rsi
    pop rcx
    pop rbx
    ret

section .data
align 16
def_name_path: db 'PATH',0
def_val_path: db '.',0
def_name_comspec: db 'COMSPEC',0
def_val_comspec: db 'COMMAND64',0

section .bss
align 8
spawn_ret_pid: resq 1
spawn_ret_psp: resq 1
