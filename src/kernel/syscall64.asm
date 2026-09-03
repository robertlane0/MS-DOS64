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

%define MAXCOM 0x4C    ; 76 — extend for Phase6 alloc/free/resize (DOS 2.0 48h/49h/4Ah)
%define MAXCALL 36
%define IOSTACK_SIZE 1024
%define DSKSTACK_SIZE 1024

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
    movzx ebx, byte [rel SPSAVE64]
    ret

syscall_dispatch64:
    cmp eax, MAXCOM
    ja .dispatch_bad
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    push rax          ; 15th push balances leave64's 15 pops; [rsp] = func (AH)
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
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
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
    dq handler_inuse      ; 4B 75
    dq handler_abort      ; 4C 76 exit

section .text
handler_abort:
    mov rsi, [rel SPSAVE64]
    jmp qword [rel EXITHOLD64]

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

demo_les_lds:
    mov rdi, [rel DMAADD64_SC]
    mov rsi, [rel SPSAVE64]
    mov rax, [rsi + STKPTRS64.rax_save]
    ret
