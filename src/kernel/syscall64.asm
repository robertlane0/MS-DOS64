bits 64
default rel
%include "include/regs.inc"
%include "include/fcb.inc"
%include "include/dpb.inc"
extern vga_putc
extern vga_print
extern mem_alloc64
extern mem_free64
extern mem_resize64
extern mem_max_free64
extern mem_bytes_to_para
extern mem_para_to_bytes
extern proc_spawn64
extern proc_terminate64
extern proc_exit_current64
extern proc_init64
extern proc_get_psp64
extern proc_get_current64
section .text
global syscall_init
global syscall_dispatch64
global savregs64
global leave64
global cmd_entry64
global dos_entry64
global iretq64
global get_dma64
global set_dma64
global handler_conout
global handler_prtbuf
global handler_in
global handler_abort
global handler_alloc_mem
global handler_free_mem
global handler_resize_mem
global handler_exec
global handler_exit_process

%define MAXCOM 0x4C    ; 76 — extend for Phase6 alloc/free/resize (DOS 2.0 48h/49h/4Ah)
%define MAXCALL 36
%define IOSTACK_SIZE 4096
%define DSKSTACK_SIZE 4096

section .bss
align 16
SPSAVE64:  resq 1
SSSAVE64:  resq 1
CONTSTK64: resq 1
IOSTACK64: resb IOSTACK_SIZE
IOSTACK_TOP64:
DSKSTACK64: resb DSKSTACK_SIZE
DSKSTACK_TOP64:
SAV_EXIT64: resq 1
EXITHOLD64: resq 2
DMAADD64_SC: resq 1
THISDRV64: resb 1
CURDRV64: resb 1
exec_ret_pid: resq 1
exec_ret_psp: resq 1
global exec_dbg_pid
exec_dbg_pid: resq 1

section .text
syscall_init:
    push rax
    xor rax, rax
    mov [rel SPSAVE64], rax
    mov [rel SSSAVE64], rax
    mov byte [rel THISDRV64], 0
    mov byte [rel CURDRV64], 0
    pop rax
    ret

; savregs64
savregs64:
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax
    mov [rel SPSAVE64], rsp
    mov rax, ss
    mov [rel SSSAVE64], rax
    mov rax, [rsp]
    shr rax, 8
    and eax, 0xFF
    cmp eax, 12
    jle .sav_use_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .sav_done
.sav_use_io:
    lea rsp, [rel IOSTACK_TOP64]
.sav_done:
    and rsp, ~15
    sti
    mov rbx, [rel SPSAVE64]
    movzx ebx, byte [rbx+1]   ; AH = function (was byte [SPSAVE64] = pointer low byte, Phase8 fix)
    ret

syscall_dispatch64:
    cmp ah, MAXCOM         ; AH=function (was cmp eax,MAXCOM which compared 0x4B00>0x4C, always bad; Phase8 fix)
    ja .dispatch_bad
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax          ; 15th push balances leave64's 15 pops; [rsp] = func (AH)
                      ; Order matches savregs64/STKPTRS64: [rsp]=RAX,+8=RBX,+16=RCX...
                      ; (Phase8 fix: was rbx..rax scrambled, corrupted R12/R13 counts)
    mov [rel SPSAVE64], rsp
    mov rax, ss
    mov [rel SSSAVE64], rax
    ; Recover DOS function number from saved RAX (AH), like 16-bit
    ; SAVREGS (MSDOS.ASM: S = AH). Select IOSTACK (func<=12) / DSKSTACK.
    mov rax, [rsp]
    shr rax, 8
    and eax, 0xFF
    mov r8d, eax
    cmp r8d, 12
    jle .dispatch_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .dispatch_after
.dispatch_io:
    lea rsp, [rel IOSTACK_TOP64]
.dispatch_after:
    and rsp, ~15
    mov rbx, r8
    shl rbx, 3
    lea rax, [rel DISPATCH64]
    add rax, rbx
    mov rax, [rax]
    call rax
    jmp leave64
.dispatch_bad:
    mov al, 0
    ret

leave64:
    cli
    mov rsp, [rel SPSAVE64]
    mov rax, [rel SSSAVE64]
    mov ss, ax
    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
    ret

iretq64:
    iretq

get_dma64:
    mov rax, [rel DMAADD64_SC]
    ret

set_dma64:
    mov [rel DMAADD64_SC], rdi
    ret

set_dma_from_legacy:
    jmp set_dma64

cmd_entry64:
    cmp ah, MAXCOM
    jbe savregs64
    mov al, 0
    iretq

dos_entry64:
    mov ah, cl
    cmp cl, MAXCALL
    ja .dos_bad
    jmp savregs64
.dos_bad:
    mov al, 0
    iretq

section .data
align 8
DISPATCH64:
    dq handler_abort      ; 00 ABORT
    dq handler_conin      ; 01
    dq handler_conout     ; 02
    dq handler_reader     ; 03
    dq handler_punch      ; 04
    dq handler_list       ; 05
    dq handler_rawio      ; 06
    dq handler_rawinp     ; 07
    dq handler_in         ; 08
    dq handler_prtbuf     ; 09 $-print
    dq handler_bufin      ; 0A
    dq handler_constat    ; 0B
    dq handler_flushkb    ; 0C
    dq handler_dskreset   ; 0D
    dq handler_seldsk     ; 0E
    dq handler_open       ; 0F
    dq handler_close      ; 10
    dq handler_srchfrst   ; 11
    dq handler_srchnxt    ; 12
    dq handler_delete     ; 13
    dq handler_seqrd      ; 14
    dq handler_seqwrt     ; 15
    dq handler_create     ; 16
    dq handler_rename     ; 17
    dq handler_inuse      ; 18
    dq handler_getdrv     ; 19
    dq handler_setdma     ; 1A 26
    dq handler_getfatpt   ; 1B 27
    dq handler_getfatptdl ; 1C 28
    dq handler_getrdonly  ; 1D 29
    dq handler_setattrib  ; 1E 30
    dq handler_getdskpt   ; 1F 31
    dq handler_usercode   ; 20 32
    dq handler_rndrd      ; 21 33
    dq handler_rndwrt     ; 22 34
    dq handler_filesize   ; 23 35
    dq handler_setrndrec  ; 24 36
    dq handler_setvect    ; 25 37 0025h set vector
    dq handler_newbase    ; 26 38 0026h newbase/get mem size (stub)
    dq handler_blkrd      ; 27 39
    dq handler_blkwrt     ; 28 40
    dq handler_makefcb    ; 29 41
    dq handler_getdate    ; 2A 42
    dq handler_setdate    ; 2B 43
    dq handler_gettime    ; 2C 44
    dq handler_settime    ; 2D 45
    dq handler_verify     ; 2E 46
    dq handler_inuse      ; 2F 47 stub
    dq handler_inuse      ; 30 48 stub (gap to 0x48)
    dq handler_inuse      ; 31
    dq handler_inuse      ; 32
    dq handler_inuse      ; 33
    dq handler_inuse      ; 34
    dq handler_inuse      ; 35
    dq handler_inuse      ; 36
    dq handler_inuse      ; 37
    dq handler_inuse      ; 38
    dq handler_inuse      ; 39
    dq handler_inuse      ; 3A
    dq handler_inuse      ; 3B
    dq handler_inuse      ; 3C
    dq handler_inuse      ; 3D
    dq handler_inuse      ; 3E
    dq handler_inuse      ; 3F
    dq handler_inuse      ; 40
    dq handler_inuse      ; 41
    dq handler_inuse      ; 42
    dq handler_inuse      ; 43
    dq handler_inuse      ; 44
    dq handler_inuse      ; 45
    dq handler_inuse      ; 46
    dq handler_inuse      ; 47
    dq handler_alloc_mem  ; 48 72 AH=48h ALLOC (paragraphs->bytes)
    dq handler_free_mem   ; 49 73 AH=49h FREE
    dq handler_resize_mem ; 4A 74 AH=4Ah SETBLK/RESIZE
    dq handler_exec       ; 4B 75 AH=4Bh EXEC (Phase8: proc_spawn64)
    dq handler_exit_process ; 4C 76 AH=4Ch EXIT (Phase8: proc_exit_current64)

section .text
; Phase8: INT20h ABORT (MSDOS.ASM:1356) — terminate current with code 0.
; Old code jmp [EXITHOLD64] (zero -> #GP). Now calls proc_exit_current(0).
; If current is kernel (pid0), just returns AL=0 (no halt, test-safe).
handler_abort:
    push rdi
    push rsi
    push rcx
    xor edi, edi
    call proc_exit_current64
    ; RAX 0 exited child, 1 was kernel -> both OK for abort path
    xor eax, eax
    pop rcx
    pop rsi
    pop rdi
    ret

handler_conin:
    call handler_in
    mov dl, al
    call handler_conout
    ret

handler_conout:
    movzx rdi, dl
    call vga_putc
    ret

%macro STUB_HANDLER 1
%1:
    mov al, 0
    ret
%endmacro

STUB_HANDLER handler_reader
STUB_HANDLER handler_punch
STUB_HANDLER handler_list
STUB_HANDLER handler_rawio
STUB_HANDLER handler_rawinp
STUB_HANDLER handler_in
STUB_HANDLER handler_constat
STUB_HANDLER handler_flushkb
STUB_HANDLER handler_dskreset
STUB_HANDLER handler_seldsk
STUB_HANDLER handler_open
STUB_HANDLER handler_close
STUB_HANDLER handler_srchfrst
STUB_HANDLER handler_srchnxt
STUB_HANDLER handler_delete
STUB_HANDLER handler_seqrd
STUB_HANDLER handler_seqwrt
STUB_HANDLER handler_create
STUB_HANDLER handler_rename
STUB_HANDLER handler_inuse
STUB_HANDLER handler_getdrv
STUB_HANDLER handler_getfatpt
STUB_HANDLER handler_getfatptdl
STUB_HANDLER handler_getrdonly
STUB_HANDLER handler_setattrib
STUB_HANDLER handler_getdskpt
STUB_HANDLER handler_usercode
STUB_HANDLER handler_rndrd
STUB_HANDLER handler_rndwrt
STUB_HANDLER handler_filesize
STUB_HANDLER handler_setrndrec
STUB_HANDLER handler_setvect
STUB_HANDLER handler_newbase
STUB_HANDLER handler_blkrd
STUB_HANDLER handler_blkwrt
STUB_HANDLER handler_makefcb
STUB_HANDLER handler_getdate
STUB_HANDLER handler_setdate
STUB_HANDLER handler_gettime
STUB_HANDLER handler_settime
STUB_HANDLER handler_verify

; ------------------------------------------------------------
; Phase6: Memory handlers — INT 21h AH=48h/49h/4Ah (DOS 2.0+)
;   Demonstrate paragraph->byte conversion (SHL 4) and flat 64-bit.
;   Handler called via DISPATCH64[AH*8] from syscall_dispatch64.
;   For trap, RBX holds user BX (paragraphs or segment). For direct
;   call, RDI holds bytes/linear. We support both: if RDI !=0 use it,
;   else use RBX paragraphs*16. Return AL 0 success, AH error, RAX linear.
; ------------------------------------------------------------
handler_alloc_mem:
    push rbx
    push rcx
    push rdx
    ; Try direct RDI bytes first (Phase6 tests call with RDI)
    test rdi, rdi
    jnz .use_rdi
    ; else use RBX paragraphs (from trap frame or caller RBX)
    mov rax, rbx
    shl rax, 4              ; para->bytes
    mov rdi, rax
.use_rdi:
    call mem_alloc64
    test rax, rax
    jz .fail_a
    ; success: RAX = linear, set AL=0, also update trap frame if via INT21
    ; If called via dispatch, need to write back to SPSAVE frame
    push rax
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame
    mov [rbx + STKPTRS64.rax_save], rax
    mov byte [rbx + STKPTRS64.rax_save], 0 ; AL 0 success
    ; Also store max free in RBX save for failure case? Keep RBX as is
.no_frame:
    pop rax
    clc                   ; success, RAX = linear intact
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_a:
    call mem_max_free64
    mov rcx, rax            ; max free bytes
    add rcx, 15
    shr rcx, 4              ; to paragraphs
    push rcx
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame2
    mov [rbx + STKPTRS64.rbx_save], rcx
    mov qword [rbx + STKPTRS64.rax_save], 0
    mov byte [rbx + STKPTRS64.rax_save+1], 8 ; AH=8 insufficient memory (DOS error)
.no_frame2:
    pop rcx
    mov rax, rcx            ; also return max in RAX for direct caller
    mov al, 1
    stc
    pop rdx
    pop rcx
    pop rbx
    ret

handler_free_mem:
    push rbx
    ; RDI = linear if direct, else ES:BX paragraph segment? For trap, ES:BX linear is in RDI? Simplify direct.
    test rdi, rdi
    jnz .use_rdi_f
    mov rdi, rbx
    ; If BX was paragraphs segment, convert: linear = BX*16
    shl rdi, 4
    add rdi, 0x200000        ; heuristic? For direct we expect already linear
.use_rdi_f:
    call mem_free64
    jc .fail_f
    mov al, 0
    pop rbx
    ret
.fail_f:
    mov al, 1
    stc
    pop rbx
    ret

handler_resize_mem:
    push rbx
    push rsi
    ; RDI = linear, RSI = new size bytes or RBX paragraphs + RCX?
    test rsi, rsi
    jnz .use_rsi
    mov rsi, rbx
    shl rsi, 4              ; para->bytes
.use_rsi:
    call mem_resize64
    test rax, rax
    jnz .fail_r
    mov al, 0
    pop rsi
    pop rbx
    ret
.fail_r:
    mov al, 1
    stc
    pop rsi
    pop rbx
    ret

handler_prtbuf:
    push rsi
    push rax
    mov rsi, rdx
.prt_next:
    lodsb
    cmp al, '$'
    je .prt_done
    mov dl, al
    call handler_conout
    jmp .prt_next
.prt_done:
    pop rax
    pop rsi
    ret

handler_bufin:
    mov al, 0
    ret

handler_setdma:
    mov [rel DMAADD64_SC], rdx
    ret

; ------------------------------------------------------------
; Phase8: EXEC (AH=4Bh) — spawn process from memory image
;   Direct: RDI=src linear, RSI=size bytes, RDX=cmdline (0=none),
;           RCX=cmdlen, R8=env_src (0=default)
;   Trap via DISPATCH64: same regs live (push preserves values),
;           RAX=0x4B00 (AH=4Bh). Returns pid.
;   Out: RAX=pid (0 fail), RDX=psp (0 fail), CF 0 ok / 1 fail.
;   Success = CF=0 + RAX!=0 (pid 1..). Fail = CF=1 + RAX=0.
;   Trap frame: writes pid to [SPSAVE+rax_save] + [rbx_save] for parent.
; ------------------------------------------------------------
handler_exec:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; RDI/RSI/RDX/RCX/R8 already hold args (push preserves values, regs unchanged)
    call proc_spawn64
    ; RAX=pid, RDX=psp
    mov [rel exec_dbg_pid], rax
    test rax, rax
    jz .fail_e
    mov r9, rax          ; save pid
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_e
    mov [rbx + STKPTRS64.rax_save], rax
    mov [rbx + STKPTRS64.rbx_save], rax
.no_frame_e:
    mov rax, r9          ; restore pid (proc_spawn used RAX/RDX returns; pushes didn't clobber regs except RAX/RDX)
    ; RDX already holds psp from proc_spawn? proc_spawn returns RDX=psp, but our pushes saved orig RDX.
    ; After call, RDX=psp (return). Our push/pop of rdx will restore orig RDX on pop, losing psp!
    ; So save psp in R9 as well before pops.
    mov r9, rdx          ; psp (overwrites pid save; need both) -> use stack slots
    ; Actually need both pid and psp across pops. Save to frame or static:
    mov [rel exec_ret_pid], rax
    mov [rel exec_ret_psp], r9
    clc
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rax, [rel exec_ret_pid]
    mov rdx, [rel exec_ret_psp]
    ret
.fail_e:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_ef
    mov qword [rbx + STKPTRS64.rax_save], 0
    mov qword [rbx + STKPTRS64.rbx_save], 0
.no_frame_ef:
    xor eax, eax
    xor edx, edx
    stc
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Phase8: EXIT (AH=4Ch) — terminate current process
;   Direct: RDI=exit_code (or AL from RAX=0x4Cxx for trap compat)
;   Trap: RAX=0x4Cxx, AL=code (RDI ignored if 0? we prefer AL when RDI holds stale?)
;   Out: RAX 0 ok (child exited), 1 fail (kernel current), CF accordingly.
; ------------------------------------------------------------
handler_exit_process:
    push rbx
    push rdi
    push rcx
    ; Prefer RDI if caller set it non-trivially? Trap sets RDI=stale (whatever caller RDI was).
    ; DOS passes code in AL. For 64-bit, support both: if RDI >255, use AL; else use DIL?
    ; Simplest: if RDI <256 and RAX high AH==0x4C, use AL (trap); else use RDI.
    ; Check AH:
    mov ebx, eax
    shr ebx, 8
    and ebx, 0xFF
    cmp bl, 0x4C
    jne .use_rdi
    ; AH==4Ch -> trap or direct-with-RAX: use AL
    movzx edi, al
    jmp .do_exit
.use_rdi:
    ; keep RDI as is
.do_exit:
    call proc_exit_current64
    test rax, rax
    jnz .fail_x
    xor eax, eax
    clc
    pop rcx
    pop rdi
    pop rbx
    ret
.fail_x:
    mov rax, 1
    stc
    pop rcx
    pop rdi
    pop rbx
    ret

demo_les_lds:
    mov rdi, [rel DMAADD64_SC]
    mov rsi, [rel SPSAVE64]
    mov rax, [rsi + STKPTRS64.rax_save]
    ret
